#include "service_console_bridge.h"

#include <windows.h>
#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <deque>
#include <mutex>
#include <set>
#include <string>
#include <thread>
#include <vector>

namespace {
using flutter::EncodableMap;
using flutter::EncodableValue;
using Clock = std::chrono::steady_clock;

const EncodableValue* Find(const EncodableMap& map, const char* key) {
  const auto it = map.find(EncodableValue(key));
  return it == map.end() ? nullptr : &it->second;
}
std::string String(const EncodableMap& map, const char* key) {
  const auto* value = Find(map, key);
  const auto* text = value ? std::get_if<std::string>(value) : nullptr;
  return text ? *text : std::string();
}
double Number(const EncodableMap& map, const char* key, double fallback = 0) {
  const auto* value = Find(map, key);
  if (!value) return fallback;
  if (const auto* n = std::get_if<double>(value)) return std::isfinite(*n) ? *n : fallback;
  if (const auto* n = std::get_if<int32_t>(value)) return *n;
  if (const auto* n = std::get_if<int64_t>(value)) return static_cast<double>(*n);
  return fallback;
}
std::wstring Wide(const std::string& text) {
  const int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                      text.data(), static_cast<int>(text.size()), nullptr, 0);
  if (size <= 0) return {};
  std::wstring result(size, L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(),
                      static_cast<int>(text.size()), result.data(), size);
  return result;
}
bool IsSystemProcess(HANDLE process) {
  HANDLE token = nullptr;
  if (!OpenProcessToken(process, TOKEN_QUERY, &token)) return false;
  DWORD needed = 0;
  GetTokenInformation(token, TokenUser, nullptr, 0, &needed);
  std::vector<BYTE> buffer(needed);
  BYTE sid[SECURITY_MAX_SID_SIZE];
  DWORD sid_size = sizeof(sid);
  const bool ok = needed > 0 &&
      GetTokenInformation(token, TokenUser, buffer.data(), needed, &needed) &&
      CreateWellKnownSid(WinLocalSystemSid, nullptr, sid, &sid_size) &&
      EqualSid(reinterpret_cast<TOKEN_USER*>(buffer.data())->User.Sid, sid);
  CloseHandle(token);
  return ok;
}
bool ReadExact(HANDLE pipe, void* destination, DWORD length, ULONGLONG deadline) {
  auto* bytes = static_cast<BYTE*>(destination);
  DWORD offset = 0;
  while (offset < length) {
    OVERLAPPED overlapped{};
    overlapped.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (!overlapped.hEvent) return false;
    DWORD read = 0;
    BOOL ok = ReadFile(pipe, bytes + offset, length - offset, &read, &overlapped);
    if (!ok && GetLastError() == ERROR_IO_PENDING) {
      const ULONGLONG now = GetTickCount64();
      const DWORD wait = now < deadline ? static_cast<DWORD>(deadline - now) : 0;
      if (WaitForSingleObject(overlapped.hEvent, wait) == WAIT_OBJECT_0) {
        ok = GetOverlappedResult(pipe, &overlapped, &read, FALSE);
      } else {
        CancelIoEx(pipe, &overlapped);
        GetOverlappedResult(pipe, &overlapped, &read, TRUE);
        ok = FALSE;
      }
    }
    CloseHandle(overlapped.hEvent);
    if (!ok || read == 0) return false;
    offset += read;
  }
  return true;
}
bool ReadBootstrap(const std::string& name, std::string* json) {
  constexpr char prefix[] = "\\\\.\\pipe\\LigamentConsole-";
  if (name.rfind(prefix, 0) != 0 || name.size() > 160 || !IsSystemProcess(GetCurrentProcess())) return false;
  DWORD session = 0;
  if (!ProcessIdToSessionId(GetCurrentProcessId(), &session) || session == 0) return false;
  const auto path = Wide(name);
  if (path.empty() || !WaitNamedPipeW(path.c_str(), 15000)) return false;
  HANDLE pipe = CreateFileW(path.c_str(), GENERIC_READ, 0, nullptr, OPEN_EXISTING,
                            FILE_FLAG_OVERLAPPED | SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION, nullptr);
  if (pipe == INVALID_HANDLE_VALUE) return false;
  ULONG server_pid = 0;
  DWORD server_session = MAXDWORD;
  HANDLE server = nullptr;
  if (GetNamedPipeServerProcessId(pipe, &server_pid))
    server = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, server_pid);
  const bool trusted = server && IsSystemProcess(server) &&
      ProcessIdToSessionId(server_pid, &server_session) && server_session == 0;
  if (server) CloseHandle(server);
  uint32_t length = 0;
  const ULONGLONG deadline = GetTickCount64() + 10000;
  bool ok = trusted && ReadExact(pipe, &length, sizeof(length), deadline) && length > 0 && length <= 65536;
  if (ok) {
    json->resize(length);
    ok = ReadExact(pipe, json->data(), length, deadline);
  }
  CloseHandle(pipe);
  if (!ok) json->clear();
  return ok;
}
void SendKey(WORD key, bool down, bool unicode = false) {
  INPUT input{};
  input.type = INPUT_KEYBOARD;
  input.ki.wVk = unicode ? 0 : key;
  input.ki.wScan = unicode ? key : 0;
  input.ki.dwFlags = (unicode ? KEYEVENTF_UNICODE : 0) | (down ? 0 : KEYEVENTF_KEYUP);
  if (!unicode && (key == VK_RCONTROL || key == VK_RMENU || key == VK_INSERT ||
      key == VK_DELETE || key == VK_HOME || key == VK_END || key == VK_PRIOR ||
      key == VK_NEXT || (key >= VK_LEFT && key <= VK_DOWN))) input.ki.dwFlags |= KEYEVENTF_EXTENDEDKEY;
  SendInput(1, &input, sizeof(input));
}
void SendMouse(DWORD flags, DWORD data = 0) {
  INPUT input{};
  input.type = INPUT_MOUSE;
  input.mi.dwFlags = flags;
  input.mi.mouseData = data;
  SendInput(1, &input, sizeof(input));
}
std::wstring DesktopName(HDESK desktop) {
  wchar_t name[256]{};
  DWORD needed = 0;
  if (!GetUserObjectInformationW(desktop, UOI_NAME, name, sizeof(name), &needed)) return {};
  return name;
}
WORD VirtualKey(const EncodableMap& input) {
  const auto key = String(input, "key");
  const int code = static_cast<int>(Number(input, "keyCode"));
  if (code > 0 && code < 256) return static_cast<WORD>(code);
  const std::pair<const char*, WORD> keys[] = {
    {"Enter", VK_RETURN}, {"Tab", VK_TAB}, {"Escape", VK_ESCAPE}, {"Backspace", VK_BACK},
    {"Delete", VK_DELETE}, {"Insert", VK_INSERT}, {"Home", VK_HOME}, {"End", VK_END},
    {"PageUp", VK_PRIOR}, {"PageDown", VK_NEXT}, {"ArrowLeft", VK_LEFT}, {"ArrowRight", VK_RIGHT},
    {"ArrowUp", VK_UP}, {"ArrowDown", VK_DOWN}, {"Shift", VK_SHIFT}, {"Control", VK_CONTROL},
    {"Alt", VK_MENU}, {"Meta", VK_LWIN}, {"CapsLock", VK_CAPITAL}, {" ", VK_SPACE}
  };
  for (const auto& item : keys) if (key == item.first) return item.second;
  if (key.size() >= 2 && key[0] == 'F') {
    char* end = nullptr;
    const long n = strtol(key.c_str() + 1, &end, 10);
    if (end && *end == 0 && n >= 1 && n <= 24) return static_cast<WORD>(VK_F1 + n - 1);
  }
  if (key.size() == 1) {
    const SHORT vk = VkKeyScanW(static_cast<unsigned char>(key[0]));
    if (vk != -1) return LOBYTE(vk);
  }
  return 0;
}
}  // namespace

class ServiceConsoleBridge::InputWorker {
 public:
  InputWorker() : thread_([this] { Run(); }) {}
  ~InputWorker() {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      stopped_ = true;
      queue_.clear();
    }
    ready_.notify_one();
    thread_.join();
  }
  void Lease(int64_t ms) {
    std::lock_guard<std::mutex> lock(mutex_);
    deadline_ = Clock::now() + std::chrono::milliseconds(std::clamp<int64_t>(ms, 0, 65000));
    ready_.notify_one();
  }
  void Release() {
    std::lock_guard<std::mutex> lock(mutex_);
    deadline_ = Clock::time_point{};
    queue_.clear();
    release_ = true;
    ready_.notify_one();
  }
  bool Enqueue(const EncodableMap& input) {
    const auto type = String(input, "type");
    static const std::set<std::string> allowed = {"mouse_move", "mouse_down", "mouse_up", "mouse_click",
      "click", "wheel", "mouse_wheel", "key_down", "key_up", "hotkey"};
    if (!allowed.count(type)) return false;
    std::lock_guard<std::mutex> lock(mutex_);
    if (stopped_ || Clock::now() >= deadline_) return false;
    if (type == "mouse_move" && !queue_.empty() && String(queue_.back(), "type") == type) {
      queue_.back() = input;
    } else {
      if (queue_.size() >= 256) { queue_.clear(); release_ = true; ready_.notify_one(); return false; }
      queue_.push_back(input);
    }
    ready_.notify_one();
    return true;
  }
 private:
  void ReleasePressed() {
    for (WORD key : keys_) SendKey(key, false);
    for (WORD key : unicode_) SendKey(key, false, true);
    if (buttons_ & 1) SendMouse(MOUSEEVENTF_LEFTUP);
    if (buttons_ & 2) SendMouse(MOUSEEVENTF_MIDDLEUP);
    if (buttons_ & 4) SendMouse(MOUSEEVENTF_RIGHTUP);
    keys_.clear(); unicode_.clear(); buttons_ = 0;
  }
  bool AttachInputDesktop() {
    HDESK current = OpenInputDesktop(0, FALSE, GENERIC_ALL);
    if (!current) return false;
    const auto name = DesktopName(current);
    if (desktop_ && name == desktop_name_) { CloseDesktop(current); return true; }
    ReleasePressed();
    if (!SetThreadDesktop(current)) { CloseDesktop(current); return false; }
    if (desktop_) CloseDesktop(desktop_);
    desktop_ = current;
    desktop_name_ = name;
    return true;
  }
  void Move(const EncodableMap& input) {
    int x = GetSystemMetrics(SM_XVIRTUALSCREEN), y = GetSystemMetrics(SM_YVIRTUALSCREEN);
    int width = GetSystemMetrics(SM_CXVIRTUALSCREEN), height = GetSystemMetrics(SM_CYVIRTUALSCREEN);
    if (const auto* value = Find(input, "screen_rect")) {
      if (const auto* rect = std::get_if<EncodableMap>(value)) {
        x = static_cast<int>(Number(*rect, "x", x)); y = static_cast<int>(Number(*rect, "y", y));
        width = static_cast<int>(Number(*rect, "width", width)); height = static_cast<int>(Number(*rect, "height", height));
      }
    }
    if (width <= 0 || height <= 0 || width > 65536 || height > 65536) return;
    const double nx = std::clamp(Number(input, "x"), 0.0, 1.0);
    const double ny = std::clamp(Number(input, "y"), 0.0, 1.0);
    SetCursorPos(x + static_cast<int>(nx * (width - 1)), y + static_cast<int>(ny * (height - 1)));
  }
  void Hotkey(const EncodableMap& input) {
    auto action = String(input, "action");
    if (action.empty()) action = String(input, "hotkey");
    if (action.empty()) action = String(input, "key");
    if (action == "lock") { LockWorkStation(); return; }
    std::vector<WORD> combo;
    if (action == "ctrl_alt_del") {
      // Software SAS remains governed by Windows policy. Never emulate it as ordinary key presses.
      HMODULE sas = LoadLibraryExW(L"sas.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
      if (sas) {
        auto send = reinterpret_cast<void (WINAPI*)(BOOL)>(GetProcAddress(sas, "SendSAS"));
        if (send) send(FALSE);
        FreeLibrary(sas);
      }
      return;
    }
    if (action == "win_r") combo = {VK_LWIN, 'R'};
    else if (action == "win_e") combo = {VK_LWIN, 'E'};
    else if (action == "win_d") combo = {VK_LWIN, 'D'};
    else if (action == "alt_tab") combo = {VK_MENU, VK_TAB};
    else if (action == "alt_f4") combo = {VK_MENU, VK_F4};
    else if (action == "ctrl_shift_esc") combo = {VK_CONTROL, VK_SHIFT, VK_ESCAPE};
    else if (action == "ctrl_c") combo = {VK_CONTROL, 'C'};
    else if (action == "ctrl_v") combo = {VK_CONTROL, 'V'};
    else if (action == "ctrl_a") combo = {VK_CONTROL, 'A'};
    for (WORD key : combo) SendKey(key, true);
    for (auto key = combo.rbegin(); key != combo.rend(); ++key) SendKey(*key, false);
  }
  void Execute(const EncodableMap& input) {
    const auto type = String(input, "type");
    if (type == "mouse_move") { Move(input); return; }
    if (type == "mouse_down" || type == "mouse_up" || type == "mouse_click" || type == "click") {
      Move(input);
      const int button = std::clamp(static_cast<int>(Number(input, "button")), 0, 2);
      const DWORD down[] = {MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_MIDDLEDOWN, MOUSEEVENTF_RIGHTDOWN};
      const DWORD up[] = {MOUSEEVENTF_LEFTUP, MOUSEEVENTF_MIDDLEUP, MOUSEEVENTF_RIGHTUP};
      if (type != "mouse_up") { SendMouse(down[button]); buttons_ |= 1 << button; }
      if (type != "mouse_down") { SendMouse(up[button]); buttons_ &= ~(1 << button); }
      return;
    }
    if (type == "wheel" || type == "mouse_wheel") {
      const double delta = std::clamp(Number(input, "deltaY"), -12000.0, 12000.0);
      SendMouse(MOUSEEVENTF_WHEEL, static_cast<DWORD>(static_cast<LONG>(-delta)));
      return;
    }
    if (type == "hotkey") { Hotkey(input); return; }
    if (type == "key_down" || type == "key_up") {
      const bool down = type == "key_down";
      auto text = Wide(String(input, "char"));
      if (text.empty()) text = Wide(String(input, "key"));
      const bool modifier = keys_.count(VK_CONTROL) || keys_.count(VK_MENU) || keys_.count(VK_LWIN);
      if (!modifier && (text.size() == 1 || text.size() == 2) && text[0] > 127) {
        for (wchar_t ch : text) {
          SendKey(ch, down, true);
          if (down) unicode_.insert(ch); else unicode_.erase(ch);
        }
      } else {
        const WORD key = VirtualKey(input);
        if (!key) return;
        SendKey(key, down);
        if (down) keys_.insert(key); else keys_.erase(key);
      }
    }
  }
  void Run() {
    original_desktop_ = GetThreadDesktop(GetCurrentThreadId());
    for (;;) {
      EncodableMap input;
      bool release = false;
      {
        std::unique_lock<std::mutex> lock(mutex_);
        ready_.wait_for(lock, std::chrono::milliseconds(100), [this] { return stopped_ || release_ || !queue_.empty(); });
        if (stopped_) break;
        release = release_ || Clock::now() >= deadline_;
        release_ = false;
        if (release) queue_.clear();
        else if (!queue_.empty()) { input = std::move(queue_.front()); queue_.pop_front(); }
      }
      if (release) ReleasePressed();
      if (!input.empty() && AttachInputDesktop()) Execute(input);
    }
    ReleasePressed();
    if (original_desktop_) SetThreadDesktop(original_desktop_);
    if (desktop_) CloseDesktop(desktop_);
  }
  std::mutex mutex_;
  std::condition_variable ready_;
  std::deque<EncodableMap> queue_;
  Clock::time_point deadline_{};
  bool stopped_ = false, release_ = false;
  std::thread thread_;
  HDESK original_desktop_ = nullptr, desktop_ = nullptr;
  std::wstring desktop_name_;
  std::set<WORD> keys_, unicode_;
  int buttons_ = 0;
};

ServiceConsoleBridge::ServiceConsoleBridge(flutter::BinaryMessenger* messenger)
    : input_(std::make_unique<InputWorker>()),
      channel_(std::make_unique<flutter::MethodChannel<EncodableValue>>(
          messenger, "ligament/service_console", &flutter::StandardMethodCodec::GetInstance())) {
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() == "bootstrap") {
      const auto* pipe = call.arguments() ? std::get_if<std::string>(call.arguments()) : nullptr;
      std::string json;
      if (bootstrapped_ || !pipe || !ReadBootstrap(*pipe, &json)) {
        result->Error("bootstrap_refused", "Endpoint bootstrap unavailable"); return;
      }
      bootstrapped_ = true;
      result->Success(EncodableValue(json));
      SecureZeroMemory(json.data(), json.size());
      return;
    }
    if (!bootstrapped_) { result->Error("not_authorized", "Endpoint bootstrap required"); return; }
    if (call.method_name() == "lease") {
      int64_t remaining = 0;
      if (call.arguments()) {
        if (const auto* n = std::get_if<int64_t>(call.arguments())) remaining = *n;
        else if (const auto* n = std::get_if<int32_t>(call.arguments())) remaining = *n;
      }
      input_->Lease(remaining);
      result->Success(); return;
    }
    if (call.method_name() == "releaseInput") { input_->Release(); result->Success(); return; }
    if (call.method_name() == "input") {
      const auto* map = call.arguments() ? std::get_if<EncodableMap>(call.arguments()) : nullptr;
      result->Success(EncodableValue(map && input_->Enqueue(*map))); return;
    }
    result->NotImplemented();
  });
}
ServiceConsoleBridge::~ServiceConsoleBridge() { channel_->SetMethodCallHandler(nullptr); }
