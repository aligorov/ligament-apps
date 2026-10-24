#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Присоединяемся к консоли родителя при запуске из cmd/powershell
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Инициализация COM для системного трея и WMI
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

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

  bool service_console = false;
  bool link_host_worker = false;
  bool start_minimized = false;
  bool autoshare = false;
  for (const auto& argument : command_line_arguments) {
    if (argument.rfind("--service-console=", 0) == 0) service_console = true;
    if (argument.rfind("--link-host=", 0) == 0) link_host_worker = true;
    if (argument == "--minimized") start_minimized = true;
    if (argument.rfind("--autoshare=", 0) == 0) {
      start_minimized = true;
      autoshare = true;
    }
  }
  if (service_console && link_host_worker) return EXIT_FAILURE;

  // Single-instance protection for the main GUI application.
  // Dedicated headless workers (--service-console, --link-host) and
  // autoshare forwarders have their own IPC lifecycle.
  HANDLE single_instance_mutex = nullptr;
  if (!service_console && !link_host_worker && !autoshare) {
    single_instance_mutex = ::CreateMutexW(nullptr, TRUE, L"Local\\Ligament2FA_App_SingleInstance");
    if (single_instance_mutex != nullptr && ::GetLastError() == ERROR_ALREADY_EXISTS) {
      ::CloseHandle(single_instance_mutex);
      if (!start_minimized) {
        // Bring existing window to foreground if user explicitly launched the app
        HWND existing_wnd = ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", L"Ligament 2FA Authenticator");
        if (existing_wnd != nullptr) {
          if (::IsIconic(existing_wnd)) {
            ::ShowWindow(existing_wnd, SW_RESTORE);
          } else {
            ::ShowWindow(existing_wnd, SW_SHOW);
          }
          ::SetForegroundWindow(existing_wnd);
        }
      }
      ::CoUninitialize();
      return EXIT_SUCCESS;
    }
  }

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project, service_console, link_host_worker, start_minimized);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(440, 720);
  if (!window.Create(L"Ligament 2FA Authenticator", origin, size)) {
    if (single_instance_mutex != nullptr) ::CloseHandle(single_instance_mutex);
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(false); // Поддержка сворачивания в трей

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  if (single_instance_mutex != nullptr) {
    ::CloseHandle(single_instance_mutex);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
