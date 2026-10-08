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

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(440, 720);
  if (!window.Create(L"Ligament 2FA Authenticator", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(false); // Поддержка сворачивания в трей

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
