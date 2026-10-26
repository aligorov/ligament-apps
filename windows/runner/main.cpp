#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "debug_log.h"
#include "flutter_window.h"
#include "utils.h"

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
  debug_log::Initialize(link_host_worker ? debug_log::Mode::link_host :
      service_console ? debug_log::Mode::service_console : debug_log::Mode::gui);
  debug_log::Write(link_host_worker ? "startup.mode.link_host" :
      service_console ? "startup.mode.service_console" : "startup.mode.gui");
  if (start_minimized) debug_log::Write("startup.minimized");
  if (autoshare) debug_log::Write("startup.autoshare");
  if (service_console && link_host_worker) {
    debug_log::Write("startup.mode.conflict");
    return EXIT_FAILURE;
  }

  const HRESULT com_result = ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  if (FAILED(com_result)) {
    debug_log::Write("startup.com.failed", "HRESULT", {},
                     static_cast<int64_t>(com_result));
  }
  flutter::DartProject project(L"data");

  // Single-instance protection for the main GUI application.
  // Dedicated headless workers (--service-console, --link-host) and
  // autoshare forwarders have their own IPC lifecycle.
  HANDLE single_instance_mutex = nullptr;
  if (!service_console && !link_host_worker && !autoshare) {
    single_instance_mutex = ::CreateMutexW(nullptr, TRUE, L"Local\\Ligament2FA_App_SingleInstance");
    const DWORD mutex_error = ::GetLastError();
    if (single_instance_mutex == nullptr) {
      debug_log::Write("startup.mutex.failed", {}, {}, mutex_error);
    } else if (mutex_error == ERROR_ALREADY_EXISTS) {
      debug_log::Write("startup.mutex.existing", {}, {}, mutex_error);
      ::CloseHandle(single_instance_mutex);
      HWND existing_wnd = ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", L"Ligament 2FA Authenticator");
      debug_log::Write(existing_wnd ? "startup.window.found" : "startup.window.missing");
      if (!start_minimized && existing_wnd != nullptr) {
        if (::IsIconic(existing_wnd)) {
          ::ShowWindow(existing_wnd, SW_RESTORE);
        } else {
          ::ShowWindow(existing_wnd, SW_SHOW);
        }
        ::SetForegroundWindow(existing_wnd);
      }
      debug_log::Write("startup.single_instance.exit");
      if (SUCCEEDED(com_result)) ::CoUninitialize();
      return EXIT_SUCCESS;
    } else {
      debug_log::Write("startup.mutex.created");
    }
  }

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project, service_console, link_host_worker, start_minimized);
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
