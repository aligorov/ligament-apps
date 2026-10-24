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
#include <mutex>
#include <string>
#include <thread>

namespace {

std::atomic<bool> g_blocked{false};
HHOOK g_kbd_hook = nullptr;
HHOOK g_mouse_hook = nullptr;
HANDLE g_thread = nullptr;
DWORD g_thread_id = 0;
// Событие готовности хуков: установлены ли они в потоке успешно.
HANDLE g_ready = nullptr;

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
std::wstring g_last_desktop_name;

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

HDESK FindActiveInputDesktop() {
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
  if (t.mouse_flags & MOUSEEVENTF_MOVE) {
    ClipCursor(nullptr);
    SetCursorPos(t.abs_x, t.abs_y);
  }
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
  HMODULE sas = LoadLibraryExW(L"sas.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
  if (sas) {
    auto send_sas = reinterpret_cast<void(WINAPI*)(BOOL)>(GetProcAddress(sas, "SendSAS"));
    if (send_sas) send_sas(FALSE);
    FreeLibrary(sas);
  }
  ExecuteSendVk(VK_SPACE, true);
  ExecuteSendVk(VK_SPACE, false);
}

void DesktopInputWorkerLoop() {
  HWINSTA winsta = OpenWindowStationW(L"winsta0", FALSE, MAXIMUM_ALLOWED);
  if (winsta) {
    SetProcessWindowStation(winsta);
  }
  HDESK active_desk = nullptr;
  auto last_awake_tick = std::chrono::steady_clock::now() - std::chrono::seconds(30);

  for (;;) {
    NativeInputTask task{};
    bool has_task = false;
    {
      std::unique_lock<std::mutex> lock(g_input_mutex);
      g_input_cv.wait_for(lock, std::chrono::milliseconds(1000), [] {
        return !g_input_queue.empty();
      });
      if (!g_input_queue.empty()) {
        task = g_input_queue.front();
        g_input_queue.pop_front();
        has_task = true;
      }
    }

    AttachCurrentInputDesktop(&active_desk);

    if (g_keep_awake.load(std::memory_order_relaxed)) {
      const auto now = std::chrono::steady_clock::now();
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
        ExecuteSendSas();
        break;
    }
  }
}

void EnqueueNativeInput(const NativeInputTask& task) {
  std::lock_guard<std::mutex> lock(g_input_mutex);
  if (!g_input_worker_started) {
    g_input_worker_started = true;
    std::thread(DesktopInputWorkerLoop).detach();
  }
  if (task.kind == NativeInputTask::kMouse &&
      (task.mouse_flags == (MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK)) &&
      !g_input_queue.empty() &&
      g_input_queue.back().kind == NativeInputTask::kMouse &&
      g_input_queue.back().mouse_flags == task.mouse_flags) {
    g_input_queue.back() = task;
  } else {
    if (g_input_queue.size() >= 512) {
      g_input_queue.pop_front();
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

__declspec(dllexport) int ligament_consume_desktop_changed(void) {
  return g_desktop_changed.exchange(false, std::memory_order_relaxed) ? 1 : 0;
}

// C4 (Релиз C): честный резолвинг 3+ мониторов на Windows через EnumDisplayMonitors.
__declspec(dllexport) int ligament_get_monitor_rect_by_index(int index, int* out_l, int* out_t, int* out_r, int* out_b) {
  if (!out_l || !out_t || !out_r || !out_b) return -1;
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
  return -1;
}

// Инцидент 2026-10-12 (SOS win-win, «перепутаны дисплеи»): id источника
// desktopCapturer ("screen:N") нумеруется в порядке EnumDisplayDevices,
// а прежний резолвинг шёл по индексу EnumDisplayMonitors — порядки
// различаются на 2+ мониторах, мышь оператора попадала на соседний экран.
// Здесь: EnumDisplayDevices(N) → DeviceName → ищем HMONITOR с тем же
// именем (MONITORINFOEXW.szDevice) → честный rect виртуального стола.
__declspec(dllexport) int ligament_get_monitor_rect_by_device_index(int device_index, int* out_l, int* out_t, int* out_r, int* out_b) {
  if (!out_l || !out_t || !out_r || !out_b) return -1;
  DISPLAY_DEVICEW dd{};
  dd.cb = sizeof(dd);
  if (!EnumDisplayDevicesW(nullptr, static_cast<DWORD>(device_index), &dd, 0)) return -1;
  if ((dd.StateFlags & DISPLAY_DEVICE_ATTACHED_TO_DESKTOP) == 0) return -1;

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

// Прямой захват активного экрана через GDI BitBlt в BMP (резервный канал для Recorder).
__declspec(dllexport) int ligament_capture_desktop_bmp(
    int max_w, int max_h, uint8_t* out_buf, int buf_size, int* out_len, int* out_w, int* out_h) {
  if (!out_buf || buf_size <= static_cast<int>(sizeof(BITMAPFILEHEADER) + sizeof(BITMAPINFOHEADER)) ||
      !out_len || !out_w || !out_h) {
    return -1;
  }

  HDC hScreenDC = GetDC(nullptr);
  if (!hScreenDC) return -2;

  int screen_w = GetSystemMetrics(SM_CXSCREEN);
  int screen_h = GetSystemMetrics(SM_CYSCREEN);
  if (screen_w <= 0 || screen_h <= 0) {
    ReleaseDC(nullptr, hScreenDC);
    return -3;
  }

  int target_w = screen_w;
  int target_h = screen_h;
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
    return -4;
  }

  HDC hMemDC = CreateCompatibleDC(hScreenDC);
  if (!hMemDC) {
    ReleaseDC(nullptr, hScreenDC);
    return -5;
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
    return -6;
  }

  HGDIOBJ hOld = SelectObject(hMemDC, hDIB);
  SetStretchBltMode(hMemDC, HALFTONE);
  SetBrushOrgEx(hMemDC, 0, 0, nullptr);

  StretchBlt(hMemDC, 0, 0, target_w, target_h,
             hScreenDC, 0, 0, screen_w, screen_h,
             SRCCOPY | CAPTUREBLT);

  GdiFlush();

  BITMAPFILEHEADER bmfHeader{};
  bmfHeader.bfType = 0x4D42; // 'BM'
  bmfHeader.bfSize = total_bmp_size;
  bmfHeader.bfOffBits = sizeof(BITMAPFILEHEADER) + sizeof(BITMAPINFOHEADER);

  memcpy(out_buf, &bmfHeader, sizeof(BITMAPFILEHEADER));
  memcpy(out_buf + sizeof(BITMAPFILEHEADER), &bi.bmiHeader, sizeof(BITMAPINFOHEADER));
  memcpy(out_buf + bmfHeader.bfOffBits, pBits, pixel_data_size);

  *out_len = total_bmp_size;
  *out_w = target_w;
  *out_h = target_h;

  SelectObject(hMemDC, hOld);
  DeleteObject(hDIB);
  DeleteDC(hMemDC);
  ReleaseDC(nullptr, hScreenDC);
  return 0;
}

} // extern "C"
