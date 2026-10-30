// input_block.cpp — блокировка физического ввода (клавиатура/мышь) на
// время сеанса удалённой помощи. Нативный Win32-код с собственным потоком
// с message loop: LL-хуки обязаны обрабатываться в message pump потока,
// поставившего хук — из чистого Dart/Flutter это недостижимо.
//
// Экспорт из exe (см. dllexport ниже + CMakeLists /EXPORT): Dart-агент
// вызывает через ffi.DynamicLibrary.executable().
//
// Права: WH_KEYBOARD_LL/WH_MOUSE_LL работают в обычном юзер-процессе
// (BlockInput, который использовался раньше, молча отказывает без
// администратора). Инъекционный ввод агента (SendInput с
// LLKHF_INJECTED/LLMHF_INJECTED) пропускается — инженер сохраняет
// управление машиной.

#include <windows.h>
#include <wchar.h>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <deque>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace Gdiplus {
  using std::min;
  using std::max;
}
#include <gdiplus.h>
#pragma comment(lib, "gdiplus.lib")

namespace {

std::atomic<bool> g_blocked{false};
HHOOK g_kbd_hook = nullptr;
HHOOK g_mouse_hook = nullptr;
HANDLE g_thread = nullptr;
DWORD g_thread_id = 0;
// Событие готовности хуков: установлены ли они в потоке успешно.
HANDLE g_ready = nullptr;

static ULONG_PTR g_gdiplusToken = 0;
static std::once_flag g_gdiplusInitOnce;

static void EnsureGdiplusInitialized() {
  std::call_once(g_gdiplusInitOnce, []() {
    Gdiplus::GdiplusStartupInput input;
    Gdiplus::GdiplusStartup(&g_gdiplusToken, &input, nullptr);
  });
}

static int GetEncoderClsid(const WCHAR* format, CLSID* pClsid) {
  UINT num = 0;
  UINT size = 0;
  Gdiplus::GetImageEncodersSize(&num, &size);
  if (size == 0) return -1;

  std::vector<BYTE> buf(size);
  auto pImageCodecInfo = reinterpret_cast<Gdiplus::ImageCodecInfo*>(buf.data());
  Gdiplus::GetImageEncoders(num, size, pImageCodecInfo);

  for (UINT j = 0; j < num; ++j) {
    if (wcscmp(pImageCodecInfo[j].MimeType, format) == 0) {
      *pClsid = pImageCodecInfo[j].Clsid;
      return j;
    }
  }
  return -1;
}

// Выделенный поток инъекции ввода без окон/хуков (Winlogon / UAC / Default):
// в Windows поток с HWND (главный поток Flutter) не может вызывать
// SetThreadDesktop(Winlogon), из-за чего при блокировке экрана (или простое)
// мышь и клавиатура переставали работать на экране входа Windows.
struct NativeInputTask {
  enum Kind { kUnicode, kVk, kMouse, kSas } kind;
  wchar_t ch = 0;
  WORD vk = 0;
  bool is_down = false;
  int abs_x = 0;
  int abs_y = 0;
  int norm_vx = 0;
  int norm_vy = 0;
  DWORD mouse_flags = 0;
  DWORD mouse_data = 0;
};

std::mutex g_input_mutex;
std::condition_variable g_input_cv;
std::deque<NativeInputTask> g_input_queue;
bool g_input_worker_started = false;
std::atomic<bool> g_keep_awake{false};
std::atomic<bool> g_desktop_changed{false};
std::atomic<bool> g_system_console_allowed{false};
std::wstring g_last_desktop_name;

bool IsSecureDesktop(const std::wstring& name) {
  if (name.empty()) return false;
  return (_wcsicmp(name.c_str(), L"Winlogon") == 0 ||
          _wcsicmp(name.c_str(), L"Screen-saver") == 0);
}

void ReleaseModifierKeys() {
  const WORD mod_vks[] = {
    VK_LCONTROL, VK_RCONTROL, VK_CONTROL,
    VK_LMENU, VK_RMENU, VK_MENU,
    VK_LSHIFT, VK_RSHIFT, VK_SHIFT,
    VK_LWIN, VK_RWIN
  };
  for (WORD vk : mod_vks) {
    if ((GetAsyncKeyState(vk) & 0x8000) != 0) {
      INPUT input = {};
      input.type = INPUT_KEYBOARD;
      input.ki.wVk = vk;
      input.ki.wScan = static_cast<WORD>(MapVirtualKeyW(vk, MAPVK_VK_TO_VSC));
      input.ki.dwFlags = KEYEVENTF_KEYUP;
      SendInput(1, &input, sizeof(INPUT));
    }
  }
}

std::wstring QueryDesktopName(HDESK desk) {
  if (!desk) return {};
  wchar_t buf[256]{};
  DWORD needed = 0;
  if (!GetUserObjectInformationW(desk, UOI_NAME, buf, sizeof(buf), &needed)) {
    return {};
  }
  return buf;
}

bool IsDesktopReceivingInput(HDESK desk) {
  if (!desk) return false;
  BOOL is_io = FALSE;
  DWORD needed = 0;
  if (GetUserObjectInformationW(desk, UOI_IO, &is_io, sizeof(is_io), &needed)) {
    return is_io != FALSE;
  }
  return false;
}

HWINSTA g_winsta0 = nullptr;

void EnsureProcessWindowStation() {
  if (!g_winsta0) {
    g_winsta0 = OpenWindowStationW(L"winsta0", FALSE, MAXIMUM_ALLOWED);
    if (g_winsta0) {
      SetProcessWindowStation(g_winsta0);
    }
  }
}

HDESK FindActiveInputDesktop() {
  EnsureProcessWindowStation();

  // 1. Попытка открыть текущий десктоп ввода через OpenInputDesktop
  HDESK desk = OpenInputDesktop(0, FALSE, MAXIMUM_ALLOWED);
  if (desk) {
    if (IsDesktopReceivingInput(desk)) {
      return desk;
    }
  }

  // 2. Опрос кандидатов: СТРОГО сначала Default (основной рабочий стол), затем Winlogon
  const wchar_t* candidates[] = { L"Default", L"Winlogon", L"Screen-saver" };
  HDESK fallback = desk;
  for (const wchar_t* cand_name : candidates) {
    HDESK cand = OpenDesktopW(cand_name, 0, FALSE, MAXIMUM_ALLOWED);
    if (!cand) continue;
    if (IsDesktopReceivingInput(cand)) {
      if (fallback && fallback != cand) CloseDesktop(fallback);
      return cand;
    }
    if (!fallback && wcscmp(cand_name, L"Default") == 0) {
      fallback = cand; // Default — приоритетный десктоп при смене экрана
    } else {
      CloseDesktop(cand);
    }
  }
  return fallback;
}

void AttachCurrentInputDesktop(HDESK* io_desk) {
  // Быстрая проверка: если текущий десктоп потока уже подтверждённо принимает ввод — возврат
  if (*io_desk && IsDesktopReceivingInput(*io_desk)) {
    return;
  }

  HDESK target = FindActiveInputDesktop();
  if (!target) return;

  const std::wstring name = QueryDesktopName(target);
  const bool changed = (!name.empty() && name != g_last_desktop_name);

  if (SetThreadDesktop(target)) {
    if (*io_desk) {
      CloseDesktop(*io_desk);
    }
    *io_desk = target;
    if (changed) {
      if (!g_last_desktop_name.empty()) {
        g_desktop_changed.store(true, std::memory_order_relaxed);
      }
      g_last_desktop_name = name;
    }
    return;
  }
  CloseDesktop(target);
}

void ExecuteSendVk(WORD vk, bool is_down) {
  INPUT input = {};
  input.type = INPUT_KEYBOARD;
  input.ki.wVk = vk;
  input.ki.wScan = static_cast<WORD>(MapVirtualKeyW(vk, MAPVK_VK_TO_VSC));
  input.ki.dwFlags = is_down ? 0 : KEYEVENTF_KEYUP;
  if (vk == VK_RCONTROL || vk == VK_RMENU || vk == VK_INSERT ||
      vk == VK_DELETE || vk == VK_HOME || vk == VK_END || vk == VK_PRIOR ||
      vk == VK_NEXT || (vk >= VK_LEFT && vk <= VK_DOWN)) {
    input.ki.dwFlags |= KEYEVENTF_EXTENDEDKEY;
  }
  if (SendInput(1, &input, sizeof(INPUT)) == 0) {
    keybd_event( static_cast<BYTE>(vk), static_cast<BYTE>(input.ki.wScan), input.ki.dwFlags, 0);
  }
}

void ExecuteSendUnicode(wchar_t ch, bool is_down) {
  INPUT input = {};
  input.type = INPUT_KEYBOARD;
  input.ki.wScan = ch;
  input.ki.dwFlags = KEYEVENTF_UNICODE | (is_down ? 0 : KEYEVENTF_KEYUP);
  SendInput(1, &input, sizeof(INPUT));
}

void ExecuteSendMouse(const NativeInputTask& t) {
  INPUT input = {};
  input.type = INPUT_MOUSE;
  input.mi.dx = t.norm_vx;
  input.mi.dy = t.norm_vy;
  input.mi.dwFlags = t.mouse_flags;
  input.mi.mouseData = t.mouse_data;
  if (SendInput(1, &input, sizeof(INPUT)) == 0) {
    mouse_event(t.mouse_flags, t.norm_vx, t.norm_vy, t.mouse_data, 0);
  }
}

void ExecuteSendSas() {
  HKEY hKey = nullptr;
  DWORD originalVal = 0;
  DWORD originalType = 0;
  bool hadValue = false;

  if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, L"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\System", 0, KEY_QUERY_VALUE | KEY_SET_VALUE, &hKey) == ERROR_SUCCESS) {
    DWORD dataSize = sizeof(originalVal);
    if (RegQueryValueExW(hKey, L"SoftwareSASGeneration", nullptr, &originalType, reinterpret_cast<BYTE*>(&originalVal), &dataSize) == ERROR_SUCCESS) {
      hadValue = true;
    }
    DWORD val = 3;
    RegSetValueExW(hKey, L"SoftwareSASGeneration", 0, REG_DWORD, reinterpret_cast<const BYTE*>(&val), sizeof(val));
  }
  HMODULE sas = LoadLibraryExW(L"sas.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
  if (sas) {
    auto send_sas = reinterpret_cast<void(WINAPI*)(BOOL)>(GetProcAddress(sas, "SendSAS"));
    if (send_sas) send_sas(FALSE);
    FreeLibrary(sas);
  }
  if (hKey) {
    if (hadValue) {
      RegSetValueExW(hKey, L"SoftwareSASGeneration", 0, originalType, reinterpret_cast<const BYTE*>(&originalVal), sizeof(originalVal));
    } else {
      RegDeleteValueW(hKey, L"SoftwareSASGeneration");
    }
    RegCloseKey(hKey);
  }
}

void DesktopInputWorkerLoop();

void EnsureInputWorkerStarted() {
  std::lock_guard<std::mutex> lock(g_input_mutex);
  if (!g_input_worker_started) {
    g_input_worker_started = true;
    std::thread(DesktopInputWorkerLoop).detach();
  }
}

void DesktopInputWorkerLoop() {
  EnsureProcessWindowStation();
  HDESK active_desk = nullptr;
  auto last_awake_tick = std::chrono::steady_clock::now() - std::chrono::seconds(30);
  auto last_desktop_check = std::chrono::steady_clock::now() - std::chrono::milliseconds(250);

  for (;;) {
    NativeInputTask task{};
    bool has_task = false;
    {
      std::unique_lock<std::mutex> lock(g_input_mutex);
      g_input_cv.wait_for(lock, std::chrono::milliseconds(250), [] {
        return !g_input_queue.empty();
      });
      if (!g_input_queue.empty()) {
        task = g_input_queue.front();
        g_input_queue.pop_front();
        has_task = true;
      }
    }

    const auto now = std::chrono::steady_clock::now();
    if (now - last_desktop_check >= std::chrono::milliseconds(250)) {
      last_desktop_check = now;
      AttachCurrentInputDesktop(&active_desk);
    }

    if (g_keep_awake.load(std::memory_order_relaxed)) {
      if (now - last_awake_tick >= std::chrono::seconds(15)) {
        last_awake_tick = now;
        SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED);
        INPUT keep_alive = {};
        keep_alive.type = INPUT_MOUSE;
        keep_alive.mi.dwFlags = MOUSEEVENTF_MOVE;
        SendInput(1, &keep_alive, sizeof(INPUT));
      }
    }

    if (!has_task) continue;

    const bool secure_desktop = IsSecureDesktop(g_last_desktop_name);
    if (secure_desktop && !g_system_console_allowed.load(std::memory_order_relaxed)) {
      // Interactive session is forbidden from injecting input into Winlogon/secure desktop.
      ReleaseModifierKeys();
      continue;
    }

    switch (task.kind) {
      case NativeInputTask::kUnicode:
        ExecuteSendUnicode(task.ch, task.is_down);
        break;
      case NativeInputTask::kVk:
        ExecuteSendVk(task.vk, task.is_down);
        break;
      case NativeInputTask::kMouse:
        ExecuteSendMouse(task);
        break;
      case NativeInputTask::kSas:
        if (g_system_console_allowed.load(std::memory_order_relaxed)) {
          ExecuteSendSas();
        }
        break;
    }
  }
}

void EnqueueNativeInput(const NativeInputTask& task) {
  EnsureInputWorkerStarted();
  std::lock_guard<std::mutex> lock(g_input_mutex);
  if (task.kind == NativeInputTask::kMouse &&
      (task.mouse_flags == (MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK)) &&
      !g_input_queue.empty() &&
      g_input_queue.back().kind == NativeInputTask::kMouse &&
      g_input_queue.back().mouse_flags == task.mouse_flags) {
    g_input_queue.back() = task;
  } else {
    if (g_input_queue.size() >= 512) {
      // 1. Удаляем только старые перемещения мыши
      auto it = g_input_queue.begin();
      while (it != g_input_queue.end() && g_input_queue.size() >= 512) {
        if (it->kind == NativeInputTask::kMouse && (it->mouse_flags == (MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK))) {
          it = g_input_queue.erase(it);
        } else {
          ++it;
        }
      }
      // 2. Если всё ещё переполнено — удаляем только события, НЕ являющиеся key-up и mouse-up
      if (g_input_queue.size() >= 512) {
        auto it2 = g_input_queue.begin();
        while (it2 != g_input_queue.end() && g_input_queue.size() >= 512) {
          const bool is_key_up = (it2->kind == NativeInputTask::kVk || it2->kind == NativeInputTask::kUnicode) && !it2->is_down;
          const bool is_mouse_up = (it2->kind == NativeInputTask::kMouse) &&
              ((it2->mouse_flags & (MOUSEEVENTF_LEFTUP | MOUSEEVENTF_RIGHTUP | MOUSEEVENTF_MIDDLEUP | MOUSEEVENTF_XUP)) != 0);
          if (!is_key_up && !is_mouse_up) {
            it2 = g_input_queue.erase(it2);
          } else {
            ++it2;
          }
        }
      }
    }
    g_input_queue.push_back(task);
  }
  g_input_cv.notify_one();
}

LRESULT CALLBACK KeyboardLLProc(int n_code, WPARAM w_param, LPARAM l_param) {
  if (n_code >= 0 && g_blocked.load(std::memory_order_relaxed)) {
    const KBDLLHOOKSTRUCT* k = reinterpret_cast<const KBDLLHOOKSTRUCT*>(l_param);
    if ((k->flags & LLKHF_INJECTED) == 0) {
      return 1; // физическая клавиша — гасим, инъекции проходят
    }
  }
  return CallNextHookEx(nullptr, n_code, w_param, l_param);
}

LRESULT CALLBACK MouseLLProc(int n_code, WPARAM w_param, LPARAM l_param) {
  if (n_code >= 0 && g_blocked.load(std::memory_order_relaxed)) {
    const MSLLHOOKSTRUCT* m = reinterpret_cast<const MSLLHOOKSTRUCT*>(l_param);
    if ((m->flags & LLMHF_INJECTED) == 0) {
      return 1; // физическая мышь — гасим
    }
  }
  return CallNextHookEx(nullptr, n_code, w_param, l_param);
}

DWORD WINAPI InputBlockThread(LPVOID) {
  // Инцидент 2026-10-12 (SOS win-win): без приоритета хук-поток голодал
  // под нагрузкой (видео-декод рядом) — LowLevelHooksTimeout выбрасывал
  // ВСЁ: и физический ввод пользователя, и инъекции оператора; Ctrl+Alt+Del
  // (SAS) проходил мимо хуков. Высший приоритет — proc тривиален (atomic +
  // return), задержек не даёт.
  SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_TIME_CRITICAL);
  g_kbd_hook = SetWindowsHookExW(WH_KEYBOARD_LL, KeyboardLLProc, nullptr, 0);
  g_mouse_hook = SetWindowsHookExW(WH_MOUSE_LL, MouseLLProc, nullptr, 0);
  if (g_ready != nullptr) SetEvent(g_ready);

  MSG msg;
  while (GetMessageW(&msg, nullptr, 0, 0) > 0) {
    TranslateMessage(&msg);
    DispatchMessageW(&msg);
  }
  if (g_kbd_hook != nullptr) { UnhookWindowsHookEx(g_kbd_hook); g_kbd_hook = nullptr; }
  if (g_mouse_hook != nullptr) { UnhookWindowsHookEx(g_mouse_hook); g_mouse_hook = nullptr; }
  return 0;
}

void EnsureThread() {
  if (g_thread != nullptr) return;
  g_ready = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  g_thread = CreateThread(nullptr, 0, InputBlockThread, nullptr, 0, &g_thread_id);
  if (g_ready != nullptr && g_thread != nullptr) {
    WaitForSingleObject(g_ready, 2000); // хуки встали — можно ставить флаг
  }
}

} // namespace

extern "C" {

__declspec(dllexport) int ligament_install_input_block(void) {
  __try {
    EnsureThread();
    g_blocked.store(true, std::memory_order_relaxed);
    return (g_kbd_hook != nullptr && g_mouse_hook != nullptr) ? 0 : -1;
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    return -2;
  }
}

__declspec(dllexport) int ligament_remove_input_block(void) {
  g_blocked.store(false, std::memory_order_relaxed);
  return 0;
}

// A-07 (аудит 2026-10-10): надёжный ввод Unicode-символов (русская/кириллическая
// раскладка, спецсимволы) через выделенный поток с AttachInputDesktop (Winlogon/Default).
__declspec(dllexport) void ligament_send_unicode_char(wchar_t ch, bool is_down) {
  NativeInputTask task{};
  task.kind = NativeInputTask::kUnicode;
  task.ch = ch;
  task.is_down = is_down;
  EnqueueNativeInput(task);
}

__declspec(dllexport) void ligament_send_vk(WORD vk, bool is_down) {
  NativeInputTask task{};
  task.kind = NativeInputTask::kVk;
  task.vk = vk;
  task.is_down = is_down;
  EnqueueNativeInput(task);
}

__declspec(dllexport) void ligament_send_mouse(int abs_x, int abs_y, int norm_vx, int norm_vy, DWORD flags, DWORD mouse_data) {
  NativeInputTask task{};
  task.kind = NativeInputTask::kMouse;
  task.abs_x = abs_x;
  task.abs_y = abs_y;
  task.norm_vx = norm_vx;
  task.norm_vy = norm_vy;
  task.mouse_flags = flags;
  task.mouse_data = mouse_data;
  EnqueueNativeInput(task);
}

__declspec(dllexport) void ligament_send_sas(void) {
  NativeInputTask task{};
  task.kind = NativeInputTask::kSas;
  EnqueueNativeInput(task);
}

__declspec(dllexport) void ligament_set_keep_awake(bool active) {
  g_keep_awake.store(active, std::memory_order_relaxed);
  std::lock_guard<std::mutex> lock(g_input_mutex);
  if (!g_input_worker_started) {
    g_input_worker_started = true;
    std::thread(DesktopInputWorkerLoop).detach();
  }
  g_input_cv.notify_one();
}

__declspec(dllexport) void ligament_set_desktop_scope(const char* scope) {
  bool is_sys = (scope != nullptr && strcmp(scope, "system_console") == 0);
  g_system_console_allowed.store(is_sys, std::memory_order_relaxed);
}

__declspec(dllexport) int ligament_consume_desktop_changed(void) {
  return g_desktop_changed.exchange(false, std::memory_order_relaxed) ? 1 : 0;
}

// C4 (Релиз C): честный резолвинг 3+ мониторов на Windows через EnumDisplayMonitors + фоллбэк EnumDisplaySettingsExW.
__declspec(dllexport) int ligament_get_monitor_rect_by_index(int index, int* out_l, int* out_t, int* out_r, int* out_b) {
  if (!out_l || !out_t || !out_r || !out_b || index < 0) return -1;
  struct EnumContext {
    int target_index;
    int current_index;
    RECT rect;
    bool found;
  } ctx{index, 0, {}, false};

  EnumDisplayMonitors(nullptr, nullptr, [](HMONITOR hMon, HDC, LPRECT, LPARAM data) -> BOOL {
    auto* c = reinterpret_cast<EnumContext*>(data);
    if (c->current_index == c->target_index) {
      MONITORINFO mi{};
      mi.cbSize = sizeof(mi);
      if (GetMonitorInfoW(hMon, &mi)) {
        c->rect = mi.rcMonitor;
        c->found = true;
        return FALSE;
      }
    }
    c->current_index++;
    return TRUE;
  }, reinterpret_cast<LPARAM>(&ctx));

  if (ctx.found) {
    *out_l = ctx.rect.left;
    *out_t = ctx.rect.top;
    *out_r = ctx.rect.right;
    *out_b = ctx.rect.bottom;
    return 0;
  }

  int active_idx = 0;
  for (DWORD dev_idx = 0;; ++dev_idx) {
    DISPLAY_DEVICEW dd{};
    dd.cb = sizeof(dd);
    if (!EnumDisplayDevicesW(nullptr, dev_idx, &dd, 0)) break;
    if ((dd.StateFlags & DISPLAY_DEVICE_ATTACHED_TO_DESKTOP) == 0) continue;
    if (active_idx == index) {
      DEVMODEW dm{};
      dm.dmSize = sizeof(dm);
      if (EnumDisplaySettingsExW(dd.DeviceName, ENUM_CURRENT_SETTINGS, &dm, 0) &&
          dm.dmPelsWidth > 0 && dm.dmPelsHeight > 0) {
        *out_l = static_cast<int>(dm.dmPosition.x);
        *out_t = static_cast<int>(dm.dmPosition.y);
        *out_r = static_cast<int>(dm.dmPosition.x + static_cast<LONG>(dm.dmPelsWidth));
        *out_b = static_cast<int>(dm.dmPosition.y + static_cast<LONG>(dm.dmPelsHeight));
        return 0;
      }
      break;
    }
    active_idx++;
  }
  return -1;
}

// Инцидент 2026-10-12 (SOS win-win, «перепутаны дисплеи»): id источника
// desktopCapturer ("screen:N" / "N") нумеруется в порядке EnumDisplayDevices
// (см. WebRTC GetScreenList / GetScreenRect в screen_capture_utils.cc).
// Используем EnumDisplaySettingsExW(dd.DeviceName, ENUM_CURRENT_SETTINGS) как
// основной источник физических координат монитора (идентично WebRTC GetScreenRect),
// с фоллбэком на порядковый индекс активного дисплея и EnumDisplayMonitors.
__declspec(dllexport) int ligament_get_monitor_rect_by_device_index(int device_index, int* out_l, int* out_t, int* out_r, int* out_b) {
  if (!out_l || !out_t || !out_r || !out_b || device_index < 0) return -1;
  DISPLAY_DEVICEW dd{};
  dd.cb = sizeof(dd);
  bool have_dd = EnumDisplayDevicesW(nullptr, static_cast<DWORD>(device_index), &dd, 0) &&
                 ((dd.StateFlags & DISPLAY_DEVICE_ATTACHED_TO_DESKTOP) != 0);
  if (!have_dd) {
    int active_idx = 0;
    for (DWORD i = 0;; ++i) {
      DISPLAY_DEVICEW cand{};
      cand.cb = sizeof(cand);
      if (!EnumDisplayDevicesW(nullptr, i, &cand, 0)) break;
      if ((cand.StateFlags & DISPLAY_DEVICE_ATTACHED_TO_DESKTOP) == 0) continue;
      if (active_idx == device_index) {
        dd = cand;
        have_dd = true;
        break;
      }
      active_idx++;
    }
  }
  if (!have_dd) return -1;

  DEVMODEW dm{};
  dm.dmSize = sizeof(dm);
  if (EnumDisplaySettingsExW(dd.DeviceName, ENUM_CURRENT_SETTINGS, &dm, 0) &&
      dm.dmPelsWidth > 0 && dm.dmPelsHeight > 0) {
    *out_l = static_cast<int>(dm.dmPosition.x);
    *out_t = static_cast<int>(dm.dmPosition.y);
    *out_r = static_cast<int>(dm.dmPosition.x + static_cast<LONG>(dm.dmPelsWidth));
    *out_b = static_cast<int>(dm.dmPosition.y + static_cast<LONG>(dm.dmPelsHeight));
    return 0;
  }

  struct Ctx {
    const wchar_t* want;
    RECT rect;
    bool found;
  } ctx{dd.DeviceName, {}, false};

  EnumDisplayMonitors(nullptr, nullptr, [](HMONITOR hMon, HDC, LPRECT, LPARAM data) -> BOOL {
    auto* c = reinterpret_cast<Ctx*>(data);
    MONITORINFOEXW mi{};
    mi.cbSize = sizeof(mi);
    if (GetMonitorInfoW(hMon, &mi) && wcscmp(mi.szDevice, c->want) == 0) {
      c->rect = mi.rcMonitor;
      c->found = true;
      return FALSE;
    }
    return TRUE;
  }, reinterpret_cast<LPARAM>(&ctx));

  if (!ctx.found) return -1;
  *out_l = ctx.rect.left;
  *out_t = ctx.rect.top;
  *out_r = ctx.rect.right;
  *out_b = ctx.rect.bottom;
  return 0;
}

// Прямой захват активного экрана через GDI BitBlt в BMP/JPEG (резервный канал для Recorder).
// Выполняется строго в отдельном рабочем потоке без окон и сообщений, гарантируя успешный SetThreadDesktop
// без взаимного влияния на поток инъекции ввода DesktopInputWorkerLoop.
// Поддерживает захват произвольного прямоугольника монитора (src_x, src_y, src_w, src_h)
// для корректной записи второго и последующих дисплеев на мультимониторных конфигурациях.
__declspec(dllexport) int ligament_capture_desktop_rect_bmp(
    int src_x, int src_y, int src_w, int src_h,
    int max_w, int max_h, uint8_t* out_buf, int buf_size, int* out_len, int* out_w, int* out_h) {
  if (!out_buf || buf_size <= static_cast<int>(sizeof(BITMAPFILEHEADER) + sizeof(BITMAPINFOHEADER)) ||
      !out_len || !out_w || !out_h) {
    return -1;
  }

  static std::mutex s_capture_call_mutex;
  std::unique_lock<std::mutex> call_lock(s_capture_call_mutex, std::try_to_lock);
  if (!call_lock.owns_lock()) {
    return -98; // Захват уже выполняется
  }

  int result = -1;
  int out_len_val = 0;
  int out_w_val = 0;
  int out_h_val = 0;

  std::thread capture_thread([&]() {
    struct ComInit {
      ComInit() { CoInitializeEx(nullptr, COINIT_MULTITHREADED); }
      ~ComInit() { CoUninitialize(); }
    } com_init;

    if (HMODULE user32 = GetModuleHandleW(L"user32.dll")) {
      using SetThreadDpiAwarenessContextFn = HANDLE(WINAPI*)(HANDLE);
      auto set_dpi_ctx = reinterpret_cast<SetThreadDpiAwarenessContextFn>(
          GetProcAddress(user32, "SetThreadDpiAwarenessContext"));
      if (set_dpi_ctx) {
        // DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = (HANDLE)-4
        set_dpi_ctx(reinterpret_cast<HANDLE>(static_cast<intptr_t>(-4)));
      }
    }

    EnsureProcessWindowStation();
    HDESK desk = FindActiveInputDesktop();
    if (desk) {
      SetThreadDesktop(desk);
    }

    HDC hScreenDC = GetDC(nullptr);
    if (!hScreenDC) {
      if (desk) CloseDesktop(desk);
      result = -2;
      return;
    }

    int source_x = src_x;
    int source_y = src_y;
    int source_w = src_w;
    int source_h = src_h;
    if (source_w <= 0 || source_h <= 0) {
      source_x = 0;
      source_y = 0;
      source_w = GetSystemMetrics(SM_CXSCREEN);
      source_h = GetSystemMetrics(SM_CYSCREEN);
    }
    if (source_w <= 0 || source_h <= 0) {
      ReleaseDC(nullptr, hScreenDC);
      if (desk) CloseDesktop(desk);
      result = -3;
      return;
    }

    int target_w = source_w;
    int target_h = source_h;
    if (max_w > 0 && max_h > 0 && (target_w > max_w || target_h > max_h)) {
      double scale = (std::min)(static_cast<double>(max_w) / target_w,
                                static_cast<double>(max_h) / target_h);
      target_w = static_cast<int>(target_w * scale);
      target_h = static_cast<int>(target_h * scale);
      if (target_w < 1) target_w = 1;
      if (target_h < 1) target_h = 1;
    }

    int row_stride = ((target_w * 32 + 31) / 32) * 4;
    int pixel_data_size = row_stride * target_h;
    int total_bmp_size = static_cast<int>(sizeof(BITMAPFILEHEADER) + sizeof(BITMAPINFOHEADER)) + pixel_data_size;

    if (total_bmp_size > buf_size) {
      ReleaseDC(nullptr, hScreenDC);
      if (desk) CloseDesktop(desk);
      result = -4;
      return;
    }

    HDC hMemDC = CreateCompatibleDC(hScreenDC);
    if (!hMemDC) {
      ReleaseDC(nullptr, hScreenDC);
      if (desk) CloseDesktop(desk);
      result = -5;
      return;
    }

    BITMAPINFO bi{};
    bi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    bi.bmiHeader.biWidth = target_w;
    bi.bmiHeader.biHeight = -target_h; // top-down
    bi.bmiHeader.biPlanes = 1;
    bi.bmiHeader.biBitCount = 32;
    bi.bmiHeader.biCompression = BI_RGB;

    void* pBits = nullptr;
    HBITMAP hDIB = CreateDIBSection(hMemDC, &bi, DIB_RGB_COLORS, &pBits, nullptr, 0);
    if (!hDIB || !pBits) {
      if (hDIB) DeleteObject(hDIB);
      DeleteDC(hMemDC);
      ReleaseDC(nullptr, hScreenDC);
      if (desk) CloseDesktop(desk);
      result = -6;
      return;
    }

    HGDIOBJ hOld = SelectObject(hMemDC, hDIB);
    BOOL bltOk = FALSE;

    // 1. Всегда выполняем 1:1 BitBlt из экранного DC (как в WebRTC ScreenCapturerWinGdi),
    // так как прямой StretchBlt(HALFTONE | CAPTUREBLT) по ненулевым multi-monitor координатам
    // на ряде WDDM-драйверов возвращает ошибку или чёрный кадр.
    auto captureOneToOne = [&](HDC dstDC) -> BOOL {
      BOOL ok = BitBlt(dstDC, 0, 0, source_w, source_h,
                       hScreenDC, source_x, source_y, SRCCOPY | CAPTUREBLT);
      if (!ok) {
        ok = BitBlt(dstDC, 0, 0, source_w, source_h,
                    hScreenDC, source_x, source_y, SRCCOPY);
      }
      if (!ok) {
        // Фоллбэк: если виртуальный DC не отдал прямоугольник второго монитора,
        // открываем DC конкретного дисплея по совпадению координат DEVMODEW.
        for (DWORD i = 0;; ++i) {
          DISPLAY_DEVICEW dd{};
          dd.cb = sizeof(dd);
          if (!EnumDisplayDevicesW(nullptr, i, &dd, 0)) break;
          if ((dd.StateFlags & DISPLAY_DEVICE_ATTACHED_TO_DESKTOP) == 0) continue;
          DEVMODEW dm{};
          dm.dmSize = sizeof(dm);
          if (EnumDisplaySettingsExW(dd.DeviceName, ENUM_CURRENT_SETTINGS, &dm, 0) &&
              static_cast<int>(dm.dmPosition.x) == source_x &&
              static_cast<int>(dm.dmPosition.y) == source_y) {
            HDC hMonDC = CreateDCW(L"DISPLAY", dd.DeviceName, nullptr, nullptr);
            if (hMonDC) {
              ok = BitBlt(dstDC, 0, 0, source_w, source_h, hMonDC, 0, 0, SRCCOPY | CAPTUREBLT);
              if (!ok) {
                ok = BitBlt(dstDC, 0, 0, source_w, source_h, hMonDC, 0, 0, SRCCOPY);
              }
              DeleteDC(hMonDC);
            }
            break;
          }
        }
      }
      return ok;
    };

    if (target_w == source_w && target_h == source_h) {
      bltOk = captureOneToOne(hMemDC);
    } else {
      HDC hSrcDC = CreateCompatibleDC(hScreenDC);
      if (hSrcDC) {
        BITMAPINFO srcBi{};
        srcBi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
        srcBi.bmiHeader.biWidth = source_w;
        srcBi.bmiHeader.biHeight = -source_h; // top-down
        srcBi.bmiHeader.biPlanes = 1;
        srcBi.bmiHeader.biBitCount = 32;
        srcBi.bmiHeader.biCompression = BI_RGB;
        void* pSrcBits = nullptr;
        HBITMAP hSrcDIB = CreateDIBSection(hSrcDC, &srcBi, DIB_RGB_COLORS, &pSrcBits, nullptr, 0);
        if (hSrcDIB && pSrcBits) {
          HGDIOBJ hOldSrc = SelectObject(hSrcDC, hSrcDIB);
          if (captureOneToOne(hSrcDC)) {
            SetStretchBltMode(hMemDC, HALFTONE);
            SetBrushOrgEx(hMemDC, 0, 0, nullptr);
            bltOk = StretchBlt(hMemDC, 0, 0, target_w, target_h,
                               hSrcDC, 0, 0, source_w, source_h, SRCCOPY);
          }
          SelectObject(hSrcDC, hOldSrc);
          DeleteObject(hSrcDIB);
        } else if (hSrcDIB) {
          DeleteObject(hSrcDIB);
        }
        DeleteDC(hSrcDC);
      }
    }

    if (!bltOk) {
      SelectObject(hMemDC, hOld);
      DeleteObject(hDIB);
      DeleteDC(hMemDC);
      ReleaseDC(nullptr, hScreenDC);
      if (desk) CloseDesktop(desk);
      result = -7;
      return;
    }

    GdiFlush();

    EnsureGdiplusInitialized();
    bool encodedJpeg = false;
    IStream* pStream = nullptr;
    if (SUCCEEDED(CreateStreamOnHGlobal(nullptr, TRUE, &pStream))) {
      CLSID clsidJpeg;
      if (GetEncoderClsid(L"image/jpeg", &clsidJpeg) != -1) {
        // Инициализируем Bitmap напрямую из сырых пикселей pBits (top-down), обходя баг GDI+ с HBITMAP
        Gdiplus::Bitmap gdiplusBitmap(target_w, target_h, row_stride, PixelFormat32bppRGB, static_cast<BYTE*>(pBits));
        ULONG quality = 80; // Высокая чёткость текста и UI интерфейса (~60-90 КБ)
        Gdiplus::EncoderParameters encoderParams{};
        encoderParams.Count = 1;
        encoderParams.Parameter[0].Guid = Gdiplus::EncoderQuality;
        encoderParams.Parameter[0].Type = Gdiplus::EncoderParameterValueTypeLong;
        encoderParams.Parameter[0].NumberOfValues = 1;
        encoderParams.Parameter[0].Value = &quality;

        if (gdiplusBitmap.Save(pStream, &clsidJpeg, &encoderParams) == Gdiplus::Ok) {
          HGLOBAL hGlobal = nullptr;
          if (SUCCEEDED(GetHGlobalFromStream(pStream, &hGlobal))) {
            SIZE_T jpegSize = GlobalSize(hGlobal);
            void* pData = GlobalLock(hGlobal);
            if (pData && jpegSize > 0 && jpegSize <= static_cast<SIZE_T>(buf_size)) {
              memcpy(out_buf, pData, jpegSize);
              out_len_val = static_cast<int>(jpegSize);
              out_w_val = target_w;
              out_h_val = target_h;
              result = 0;
              encodedJpeg = true;
            }
            if (pData) GlobalUnlock(hGlobal);
          }
        }
      }
      pStream->Release();
    }

    if (!encodedJpeg) {
      // Безопасный фоллбэк: стандартный bottom-up BMP (положительная высота)
      bi.bmiHeader.biHeight = target_h;
      BITMAPFILEHEADER bmfHeader{};
      bmfHeader.bfType = 0x4D42; // 'BM'
      bmfHeader.bfSize = total_bmp_size;
      bmfHeader.bfOffBits = sizeof(BITMAPFILEHEADER) + sizeof(BITMAPINFOHEADER);

      memcpy(out_buf, &bmfHeader, sizeof(BITMAPFILEHEADER));
      memcpy(out_buf + sizeof(BITMAPFILEHEADER), &bi.bmiHeader, sizeof(BITMAPINFOHEADER));
      memcpy(out_buf + bmfHeader.bfOffBits, pBits, pixel_data_size);

      out_len_val = total_bmp_size;
      out_w_val = target_w;
      out_h_val = target_h;
      result = 0;
    }

    SelectObject(hMemDC, hOld);
    DeleteObject(hDIB);
    DeleteDC(hMemDC);
    ReleaseDC(nullptr, hScreenDC);
    if (desk) CloseDesktop(desk);
  });

  capture_thread.join();

  if (result == 0) {
    *out_len = out_len_val;
    *out_w = out_w_val;
    *out_h = out_h_val;
  }
  return result;
}

__declspec(dllexport) int ligament_capture_desktop_bmp(
    int max_w, int max_h, uint8_t* out_buf, int buf_size, int* out_len, int* out_w, int* out_h) {
  return ligament_capture_desktop_rect_bmp(0, 0, 0, 0, max_w, max_h, out_buf, buf_size, out_len, out_w, out_h);
}

} // extern "C"
