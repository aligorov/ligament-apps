#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <tlhelp32.h>
#include <windows.h>

#include "debug_log.h"
#include "flutter_window.h"
#include "utils.h"

namespace {

HWND FindExistingAppWindow() {
  HWND wnd = ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", L"Ligament 2FA Authenticator");
  if (wnd != nullptr) return wnd;
  wnd = ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", L"Ligament 2FA");
  if (wnd != nullptr) return wnd;

  HWND found = nullptr;
  ::EnumWindows([](HWND hwnd, LPARAM lparam) -> BOOL {
    wchar_t class_name[256] = {0};
    if (::GetClassNameW(hwnd, class_name, _countof(class_name)) > 0) {
      if (wcscmp(class_name, L"FLUTTER_RUNNER_WIN32_WINDOW") == 0) {
        wchar_t title[256] = {0};
        ::GetWindowTextW(hwnd, title, _countof(title));
        if (wcsstr(title, L"Ligament") != nullptr) {
          *reinterpret_cast<HWND*>(lparam) = hwnd;
          return FALSE;
        }
      }
    }
    return TRUE;
  }, reinterpret_cast<LPARAM>(&found));
  return found;
}

void ActivateExistingWindow(HWND wnd) {
  if (wnd == nullptr) return;
  if (::IsIconic(wnd)) {
    ::ShowWindow(wnd, SW_RESTORE);
  } else {
    ::ShowWindow(wnd, SW_SHOW);
  }
  HWND foreground_window = ::GetForegroundWindow();
  DWORD foreground_thread_id = ::GetWindowThreadProcessId(foreground_window, nullptr);
  DWORD current_thread_id = ::GetCurrentThreadId();
  if (foreground_thread_id != 0 && foreground_thread_id != current_thread_id) {
    ::AttachThreadInput(current_thread_id, foreground_thread_id, TRUE);
    ::SetWindowPos(wnd, HWND_TOPMOST, 0, 0, 0, 0,
                   SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW);
    ::SetForegroundWindow(wnd);
    ::BringWindowToTop(wnd);
    ::SetWindowPos(wnd, HWND_NOTOPMOST, 0, 0, 0, 0,
                   SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW);
    ::AttachThreadInput(current_thread_id, foreground_thread_id, FALSE);
  } else {
    ::SetWindowPos(wnd, HWND_TOPMOST, 0, 0, 0, 0,
                   SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW);
    ::SetForegroundWindow(wnd);
    ::BringWindowToTop(wnd);
    ::SetWindowPos(wnd, HWND_NOTOPMOST, 0, 0, 0, 0,
                   SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW);
  }
}

void TerminateOrphanedInstances() {
  const DWORD current_pid = ::GetCurrentProcessId();
  HANDLE snapshot = ::CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if (snapshot == INVALID_HANDLE_VALUE) return;

  PROCESSENTRY32W entry{};
  entry.dwSize = sizeof(entry);
  if (::Process32FirstW(snapshot, &entry)) {
    do {
      if (_wcsicmp(entry.szExeFile, L"ligament_authenticator.exe") == 0 &&
          entry.th32ProcessID != current_pid) {
        HANDLE hProcess = ::OpenProcess(PROCESS_TERMINATE | SYNCHRONIZE, FALSE, entry.th32ProcessID);
        if (hProcess != nullptr) {
          debug_log::Write("startup.orphaned_process.terminate", {}, {}, entry.th32ProcessID);
          ::TerminateProcess(hProcess, 1);
          ::WaitForSingleObject(hProcess, 1000);
          ::CloseHandle(hProcess);
        }
      }
    } while (::Process32NextW(snapshot, &entry));
  }
  ::CloseHandle(snapshot);
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Присоединяемся к консоли родителя при запуске из cmd/powershell
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Deep-link ligament://rdp/<grant_id> (аудит RDP-11), ХОЛОДНЫЙ старт:
  // ОС запускает exe со ссылкой в командной строке — аргументы ниже уже
  // пробрасываются в Dart main(List<String> args), разбор URI ведёт
  // lib/services/deep_link_service.dart (ligamentUriFromArgs).
  //
  // TODO(MSI, Product.wxs — правит другой агент): зарегистрировать схему
  // в реестре установщиком, иначе Windows не знает, каким exe открывать
  // ligament://:
  //   HKCU\Software\Classes\ligament
  //     (Default) = "URL:Ligament 2FA"
  //     "URL Protocol" = ""
  //   HKCU\Software\Classes\ligament\shell\open\command
  //     (Default) = "\"[INSTALLDIR]ligament_authenticator.exe\" \"%1\""
  // Из самого приложения реестр не пишем (нужны права/чистота деинсталла).
  //
  // TODO(hot start): второй запуск с URI поднимет ВТОРОЙ экземпляр —
  // нужна single-instance логика (активация существующего окна и проброс
  // URI), отдельный этап.
  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  bool link_host_worker = false;
  bool start_minimized = false;
  bool autoshare = false;
  for (const auto& argument : command_line_arguments) {
    if (argument.rfind("--link-host=", 0) == 0) link_host_worker = true;
    if (argument == "--minimized") start_minimized = true;
    if (argument.rfind("--autoshare=", 0) == 0) {
      start_minimized = true;
      autoshare = true;
    }
  }
  debug_log::Initialize(link_host_worker ? debug_log::Mode::link_host :
      debug_log::Mode::gui);
  debug_log::Write(link_host_worker ? "startup.mode.link_host" : "startup.mode.gui");
  if (start_minimized) debug_log::Write("startup.minimized");
  if (autoshare) debug_log::Write("startup.autoshare");

  const HRESULT com_result = ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  if (FAILED(com_result)) {
    debug_log::Write("startup.com.failed", "HRESULT", {},
                     static_cast<int64_t>(com_result));
  }
  flutter::DartProject project(L"data");

  // Workers and autoshare forwarders have their own IPC lifecycle.
  HANDLE single_instance_mutex = nullptr;
  if (!link_host_worker && !autoshare) {
    single_instance_mutex = ::CreateMutexW(nullptr, TRUE, L"Local\\Ligament2FA_App_SingleInstance");
    DWORD mutex_error = ::GetLastError();
    if (single_instance_mutex != nullptr && mutex_error == ERROR_ALREADY_EXISTS) {
      debug_log::Write("startup.mutex.existing", {}, {}, mutex_error);
      HWND existing_wnd = FindExistingAppWindow();
      debug_log::Write(existing_wnd ? "startup.window.found" : "startup.window.missing");

      bool is_responsive = false;
      if (existing_wnd != nullptr) {
        DWORD_PTR result = 0;
        if (::SendMessageTimeoutW(existing_wnd, WM_NULL, 0, 0,
                                  SMTO_ABORTIFHUNG | SMTO_BLOCK, 1500,
                                  &result) != 0) {
          is_responsive = true;
        }
      }

      if (existing_wnd != nullptr && is_responsive) {
        if (!start_minimized) {
          ActivateExistingWindow(existing_wnd);
        }
        ::CloseHandle(single_instance_mutex);
        debug_log::Write("startup.single_instance.exit");
        if (SUCCEEDED(com_result)) ::CoUninitialize();
        return EXIT_SUCCESS;
      }

      // Окно не найдено либо зависло: старый процесс оставляет зомби-мьютекс
      // (например, после обновления или сбоя). Завершаем осиротевший экземпляр
      // и освобождаем мьютекс, чтобы пользователь не сталкивался с отказом запуска.
      debug_log::Write("startup.stale_instance.cleanup");
      ::CloseHandle(single_instance_mutex);
      single_instance_mutex = nullptr;
      TerminateOrphanedInstances();
      ::Sleep(300);

      single_instance_mutex = ::CreateMutexW(nullptr, TRUE, L"Local\\Ligament2FA_App_SingleInstance");
      mutex_error = ::GetLastError();
    }

    if (single_instance_mutex == nullptr) {
      debug_log::Write("startup.mutex.failed", {}, {}, mutex_error);
    } else {
      debug_log::Write("startup.mutex.created");
    }
  }

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project, link_host_worker, start_minimized);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(440, 720);
  debug_log::Write("window.create.begin");
  if (!window.Create(L"Ligament 2FA Authenticator", origin, size)) {
    debug_log::Write("window.create.failed", {}, {}, ::GetLastError());
    if (single_instance_mutex != nullptr) ::CloseHandle(single_instance_mutex);
    if (SUCCEEDED(com_result)) ::CoUninitialize();
    return EXIT_FAILURE;
  }
  debug_log::Write("window.create.ready");
  window.SetQuitOnClose(false); // Поддержка сворачивания в трей

  ::MSG msg{};
  BOOL message_result = 0;
  while ((message_result = ::GetMessage(&msg, nullptr, 0, 0)) > 0) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }
  if (message_result == -1) {
    debug_log::Write("message_loop.failed", {}, {}, ::GetLastError());
  } else {
    debug_log::Write("message_loop.exit");
  }

  if (single_instance_mutex != nullptr) {
    ::CloseHandle(single_instance_mutex);
  }

  if (SUCCEEDED(com_result)) ::CoUninitialize();
  return message_result == -1 ? EXIT_FAILURE : EXIT_SUCCESS;
}
