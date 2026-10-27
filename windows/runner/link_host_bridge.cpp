#include "link_host_bridge.h"

#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <string>
#include <vector>

namespace {
using flutter::EncodableValue;

constexpr size_t kFrameLimit = 512 * 1024;
constexpr wchar_t kPipePrefix[] = L"\\\\.\\pipe\\LigamentLinkHost-";

bool ValidPipeName(const std::string& value, std::wstring* wide) {
  constexpr size_t prefix_size = (sizeof(kPipePrefix) / sizeof(wchar_t)) - 1;
  if (value.size() != prefix_size + 32) return false;
  for (size_t i = 0; i < prefix_size; ++i) {
    if (static_cast<unsigned char>(value[i]) != kPipePrefix[i]) return false;
  }
  for (size_t i = prefix_size; i < value.size(); ++i) {
    const unsigned char c = static_cast<unsigned char>(value[i]);
    if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return false;
  }
  *wide = std::wstring(kPipePrefix);
  for (size_t i = prefix_size; i < value.size(); ++i)
    wide->push_back(static_cast<wchar_t>(value[i]));
  return true;
}

bool IsSystemProcessInSessionZero(DWORD process_id) {
  HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, process_id);
  if (!process) return false;
  HANDLE token = nullptr;
  const bool token_open = OpenProcessToken(process, TOKEN_QUERY, &token) != FALSE;
  CloseHandle(process);
  if (!token_open) return false;

  DWORD needed = 0;
  GetTokenInformation(token, TokenUser, nullptr, 0, &needed);
  std::vector<BYTE> buffer(needed);
  BYTE system_sid[SECURITY_MAX_SID_SIZE];
  DWORD sid_size = sizeof(system_sid);
  DWORD session_id = MAXDWORD;
  const bool trusted = needed > 0 &&
      GetTokenInformation(token, TokenUser, buffer.data(), needed, &needed) &&
      CreateWellKnownSid(WinLocalSystemSid, nullptr, system_sid, &sid_size) &&
      EqualSid(reinterpret_cast<TOKEN_USER*>(buffer.data())->User.Sid, system_sid) &&
      ProcessIdToSessionId(process_id, &session_id) && session_id == 0;
  CloseHandle(token);
  return trusted;
}

bool ConnectToService(const std::wstring& pipe_name, HANDLE* output) {
  if (!WaitNamedPipeW(pipe_name.c_str(), 5000)) return false;
  HANDLE pipe = CreateFileW(pipe_name.c_str(), GENERIC_READ | GENERIC_WRITE, 0,
                            nullptr, OPEN_EXISTING,
                            SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION,
                            nullptr);
  if (pipe == INVALID_HANDLE_VALUE) return false;
  ULONG server_pid = 0;
  ULONG client_pid = 0;
  const bool trusted = GetNamedPipeServerProcessId(pipe, &server_pid) &&
      GetNamedPipeClientProcessId(pipe, &client_pid) &&
      client_pid == GetCurrentProcessId() && IsSystemProcessInSessionZero(server_pid);
  if (!trusted) {
    CloseHandle(pipe);
    return false;
  }
  DWORD mode = PIPE_READMODE_MESSAGE;
  if (!SetNamedPipeHandleState(pipe, &mode, nullptr, nullptr)) {
    CloseHandle(pipe);
    return false;
  }
  *output = pipe;
  return true;
}

bool ReadFrame(HANDLE pipe, std::string* output) {
  std::vector<char> buffer(kFrameLimit);
  DWORD read = 0;
  if (!ReadFile(pipe, buffer.data(), static_cast<DWORD>(buffer.size()), &read, nullptr) ||
      read == 0 || read > kFrameLimit) {
    SecureZeroMemory(buffer.data(), buffer.size());
    return false;
  }
  output->assign(buffer.data(), read);
  SecureZeroMemory(buffer.data(), buffer.size());
  return true;
}
}  // namespace

LinkHostBridge::LinkHostBridge(flutter::BinaryMessenger* messenger, HWND window_handle)
    : window_handle_(window_handle),
      channel_(std::make_unique<flutter::MethodChannel<EncodableValue>>(
          messenger, "ligament/link_host",
          &flutter::StandardMethodCodec::GetInstance())) {
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (call.method_name() == "bringToFront") {
      if (window_handle_ != nullptr) {
        if (::IsIconic(window_handle_)) {
          ::ShowWindow(window_handle_, SW_RESTORE);
        } else {
          ::ShowWindow(window_handle_, SW_SHOW);
        }
        HWND foreground_window = ::GetForegroundWindow();
        DWORD foreground_thread_id = ::GetWindowThreadProcessId(foreground_window, nullptr);
        DWORD current_thread_id = ::GetCurrentThreadId();
        if (foreground_thread_id != 0 && foreground_thread_id != current_thread_id) {
          ::AttachThreadInput(current_thread_id, foreground_thread_id, TRUE);
          ::SetWindowPos(window_handle_, HWND_TOPMOST, 0, 0, 0, 0,
                         SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW);
          ::SetForegroundWindow(window_handle_);
          ::BringWindowToTop(window_handle_);
          ::AttachThreadInput(current_thread_id, foreground_thread_id, FALSE);
        } else {
          ::SetWindowPos(window_handle_, HWND_TOPMOST, 0, 0, 0, 0,
                         SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW);
          ::SetForegroundWindow(window_handle_);
          ::BringWindowToTop(window_handle_);
        }
      }
      result->Success();
      return;
    }
    if (call.method_name() == "bootstrap") {
      const auto* value = call.arguments()
          ? std::get_if<std::string>(call.arguments()) : nullptr;
      std::wstring pipe_name;
      if (pipe_ != INVALID_HANDLE_VALUE || !value || !ValidPipeName(*value, &pipe_name) ||
          !ConnectToService(pipe_name, &pipe_)) {
        result->Error("link_worker_pipe_refused", "Link worker pipe unavailable");
        return;
      }
      std::string bootstrap;
      if (!ReadFrame(pipe_, &bootstrap)) {
        CloseHandle(pipe_);
        pipe_ = INVALID_HANDLE_VALUE;
        result->Error("link_worker_bootstrap_failed", "Link worker bootstrap unavailable");
        return;
      }
      result->Success(EncodableValue(bootstrap));
      SecureZeroMemory(bootstrap.data(), bootstrap.size());
      return;
    }
    if (pipe_ == INVALID_HANDLE_VALUE) {
      result->Error("link_worker_not_ready", "Link worker bootstrap required");
      return;
    }
    if (call.method_name() == "send") {
      const auto* frame = call.arguments()
          ? std::get_if<std::string>(call.arguments()) : nullptr;
      if (!frame || frame->empty() || frame->size() > kFrameLimit) {
        result->Error("invalid_link_worker_frame", "Invalid Link worker frame");
        return;
      }
      DWORD written = 0;
      const bool okay = WriteFile(pipe_, frame->data(), static_cast<DWORD>(frame->size()),
                                  &written, nullptr) && written == frame->size();
      result->Success(EncodableValue(okay));
      return;
    }
    if (call.method_name() == "receive") {
      DWORD message_size = 0;
      if (!PeekNamedPipe(pipe_, nullptr, 0, nullptr, nullptr, &message_size)) {
        result->Error("link_worker_pipe_failed", "Link worker pipe closed");
        return;
      }
      if (message_size == 0) {
        result->Success(EncodableValue());
        return;
      }
      if (message_size > kFrameLimit) {
        result->Error("link_worker_frame_too_large", "Link worker frame exceeds limit");
        return;
      }
      std::string frame;
      if (!ReadFrame(pipe_, &frame)) {
        result->Error("link_worker_pipe_failed", "Could not read Link worker frame");
        return;
      }
      result->Success(EncodableValue(frame));
      SecureZeroMemory(frame.data(), frame.size());
      return;
    }
    if (call.method_name() == "close") {
      ClosePipe();
      result->Success();
      return;
    }
    result->NotImplemented();
  });
}

LinkHostBridge::~LinkHostBridge() {
  channel_->SetMethodCallHandler(nullptr);
  std::lock_guard<std::mutex> lock(mutex_);
  ClosePipe();
}

void LinkHostBridge::ClosePipe() {
  if (pipe_ != INVALID_HANDLE_VALUE) {
    CloseHandle(pipe_);
    pipe_ = INVALID_HANDLE_VALUE;
  }
}
