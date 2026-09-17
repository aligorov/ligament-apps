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
#include <atomic>

namespace {

std::atomic<bool> g_blocked{false};
HHOOK g_kbd_hook = nullptr;
HHOOK g_mouse_hook = nullptr;
HANDLE g_thread = nullptr;
DWORD g_thread_id = 0;
// Событие готовности хуков: установлены ли они в потоке успешно.
HANDLE g_ready = nullptr;

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

} // extern "C"
