#include "../runner/link_pipe_session.h"

#include <iostream>
#include <stdexcept>
#include <string>

void Check(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}

int main() {
  try {
    const auto zero = CheckLinkPipeSession(nullptr, [](HANDLE, PULONG session) {
      *session = 0;
      return TRUE;
    });
    Check(zero.status == LinkPipeSessionStatus::trusted, "Session 0 refused");
    const auto desktop = CheckLinkPipeSession(nullptr, [](HANDLE, PULONG session) {
      *session = 1;
      return TRUE;
    });
    Check(desktop.status == LinkPipeSessionStatus::not_session_zero,
          "interactive pipe accepted as service");
    const auto denied = CheckLinkPipeSession(nullptr, [](HANDLE, PULONG) {
      SetLastError(ERROR_ACCESS_DENIED);
      return FALSE;
    });
    Check(denied.status == LinkPipeSessionStatus::query_failed &&
          denied.error == ERROR_ACCESS_DENIED, "query failure hidden");

    // Exercise the real Windows API using the CLIENT end, as the GUI does.
    // No SCM service installation or elevation is required by this test.
    const std::wstring name = L"\\\\.\\pipe\\LigamentSessionTest-" +
        std::to_wstring(GetCurrentProcessId());
    HANDLE server = CreateNamedPipeW(name.c_str(), PIPE_ACCESS_DUPLEX,
        PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_WAIT,
        1, 512, 512, 0, nullptr);
    Check(server != INVALID_HANDLE_VALUE, "create test pipe failed");
    HANDLE client = CreateFileW(name.c_str(), GENERIC_READ | GENERIC_WRITE,
        0, nullptr, OPEN_EXISTING, SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION, nullptr);
    if (client == INVALID_HANDLE_VALUE) {
      CloseHandle(server);
      throw std::runtime_error("connect test pipe failed");
    }
    DWORD expected = MAXDWORD;
    const bool own_session_read = ProcessIdToSessionId(GetCurrentProcessId(), &expected) != FALSE;
    const auto actual = CheckLinkPipeSession(client);
    CloseHandle(client);
    CloseHandle(server);
    Check(own_session_read, "cannot read own session");
    Check(actual.status != LinkPipeSessionStatus::query_failed,
          "pipe session cannot be queried from client handle");
    Check(actual.session == expected, "client pipe query returned wrong server session");
    Check((actual.status == LinkPipeSessionStatus::trusted) == (expected == 0),
          "real session classification is wrong");
    std::cout << "Link pipe session checks passed\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
