#define WIN32_LEAN_AND_MEAN
#include "console_host_process.h"

#include <bcrypt.h>
#include <sddl.h>
#include <userenv.h>
#include <wtsapi32.h>

#include <cstdint>
#include <vector>

namespace {

constexpr DWORD kBootstrapTimeoutMs = 15000;
constexpr DWORD kMonitorIntervalMs = 250;
constexpr size_t kBootstrapLimit = 64 * 1024;

class Handle {
 public:
  explicit Handle(HANDLE handle = nullptr) : handle_(handle) {}
  ~Handle() { Reset(); }
  Handle(const Handle&) = delete;
  Handle& operator=(const Handle&) = delete;
  HANDLE get() const { return handle_; }
  explicit operator bool() const {
    return handle_ && handle_ != INVALID_HANDLE_VALUE;
  }
  void Reset(HANDLE value = nullptr) {
    if (*this) CloseHandle(handle_);
    handle_ = value;
  }

 private:
  HANDLE handle_;
};

bool IsUuid(const std::string& value) {
  if (value.size() != 36) return false;
  for (size_t i = 0; i < value.size(); ++i) {
    if (i == 8 || i == 13 || i == 18 || i == 23) {
      if (value[i] != '-') return false;
    } else if (!((value[i] >= '0' && value[i] <= '9') ||
                 (value[i] >= 'a' && value[i] <= 'f') ||
                 (value[i] >= 'A' && value[i] <= 'F'))) {
      return false;
    }
  }
  return true;
}

bool IsHostToken(const std::string& value) {
  if (value.size() < 32 || value.size() > 2048) return false;
  for (unsigned char c : value) {
    if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
          (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.')) {
      return false;
    }
  }
  return true;
}

std::string Utf8(const std::wstring& value) {
  if (value.empty()) return {};
  const int size = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
      value.data(), static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
  if (!size) return {};
  std::string output(size, '\0');
  WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
      static_cast<int>(value.size()), output.data(), size, nullptr, nullptr);
  return output;
}

std::string JsonString(const std::string& value) {
  static const char hex[] = "0123456789abcdef";
  std::string output = "\"";
  for (unsigned char c : value) {
    if (c == '\\' || c == '"') {
      output += '\\';
      output += static_cast<char>(c);
    } else if (c < 0x20) {
      output += "\\u00";
      output += hex[c >> 4];
      output += hex[c & 15];
    } else {
      output += static_cast<char>(c);
    }
  }
  return output + "\"";
}

bool EnablePrivilege(HANDLE token, const wchar_t* name) {
  TOKEN_PRIVILEGES privileges = {};
  privileges.PrivilegeCount = 1;
  if (!LookupPrivilegeValueW(nullptr, name, &privileges.Privileges[0].Luid)) {
    return false;
  }
  privileges.Privileges[0].Attributes = SE_PRIVILEGE_ENABLED;
  SetLastError(ERROR_SUCCESS);
  return AdjustTokenPrivileges(token, FALSE, &privileges, 0, nullptr, nullptr) &&
      GetLastError() == ERROR_SUCCESS;
}

HANDLE SystemTokenForSession(DWORD session) {
  HANDLE process_token = nullptr;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY | TOKEN_DUPLICATE |
          TOKEN_ADJUST_PRIVILEGES, &process_token)) return nullptr;
  Handle source(process_token);
  DWORD needed = 0;
  GetTokenInformation(source.get(), TokenUser, nullptr, 0, &needed);
  if (!needed) return nullptr;
  std::vector<unsigned char> buffer(needed);
  if (!GetTokenInformation(source.get(), TokenUser, buffer.data(), needed,
          &needed) || !IsWellKnownSid(
          reinterpret_cast<TOKEN_USER*>(buffer.data())->User.Sid,
          WinLocalSystemSid)) return nullptr;
  if (!EnablePrivilege(source.get(), L"SeTcbPrivilege") ||
      !EnablePrivilege(source.get(), L"SeAssignPrimaryTokenPrivilege") ||
      !EnablePrivilege(source.get(), L"SeIncreaseQuotaPrivilege")) return nullptr;
  HANDLE token = nullptr;
  if (!DuplicateTokenEx(source.get(), TOKEN_QUERY | TOKEN_DUPLICATE |
          TOKEN_ASSIGN_PRIMARY | TOKEN_ADJUST_DEFAULT | TOKEN_ADJUST_SESSIONID,
          nullptr, SecurityImpersonation, TokenPrimary, &token)) return nullptr;
  if (!SetTokenInformation(token, TokenSessionId, &session, sizeof(session))) {
    CloseHandle(token);
    return nullptr;
  }
  return token;
}

std::wstring AppPath() {
  std::vector<wchar_t> path(32768, L'\0');
  const DWORD size = GetModuleFileNameW(nullptr, path.data(),
      static_cast<DWORD>(path.size()));
  if (!size || size >= path.size()) return {};
  std::wstring result(path.data(), size);
  const size_t slash = result.find_last_of(L"\\/");
  if (slash == std::wstring::npos) return {};
  result.resize(slash + 1);
  result += L"ligament_authenticator.exe";
  const DWORD attributes = GetFileAttributesW(result.c_str());
  if (attributes == INVALID_FILE_ATTRIBUTES ||
      (attributes & FILE_ATTRIBUTE_DIRECTORY)) return {};
  return result;
}

std::wstring NewPipeName() {
  unsigned char random[16] = {};
  if (BCryptGenRandom(nullptr, random, sizeof(random),
          BCRYPT_USE_SYSTEM_PREFERRED_RNG) < 0) return {};
  static const wchar_t hex[] = L"0123456789abcdef";
  std::wstring value = L"\\\\.\\pipe\\LigamentConsole-";
  for (unsigned char c : random) {
    value += hex[c >> 4];
    value += hex[c & 15];
  }
  return value;
}

// Always complete a cancelled OVERLAPPED before its storage goes away.
bool AwaitIo(HANDLE pipe, OVERLAPPED& operation, HANDLE stop, HANDLE child,
             DWORD timeout, DWORD& transferred) {
  HANDLE handles[] = {operation.hEvent, stop, child};
  if (WaitForMultipleObjects(3, handles, FALSE, timeout) == WAIT_OBJECT_0) {
    return GetOverlappedResult(pipe, &operation, &transferred, FALSE) != FALSE;
  }
  CancelIoEx(pipe, &operation);
  GetOverlappedResult(pipe, &operation, &transferred, TRUE);
  return false;
}

bool BootstrapChild(HANDLE pipe, HANDLE child, DWORD child_pid, HANDLE stop,
                    const std::string& json) {
  Handle event(CreateEventW(nullptr, TRUE, FALSE, nullptr));
  if (!event) return false;
  OVERLAPPED operation = {};
  operation.hEvent = event.get();
  DWORD transferred = 0;
  BOOL connected = ConnectNamedPipe(pipe, &operation);
  DWORD error = connected ? ERROR_SUCCESS : GetLastError();
  if (!connected && error != ERROR_PIPE_CONNECTED &&
      (error != ERROR_IO_PENDING || !AwaitIo(pipe, operation, stop, child,
          kBootstrapTimeoutMs, transferred))) return false;
  ULONG client_pid = 0;
  if (!GetNamedPipeClientProcessId(pipe, &client_pid) ||
      client_pid != child_pid) return false;
  std::vector<unsigned char> frame(4 + json.size());
  const auto size = static_cast<uint32_t>(json.size());
  for (size_t i = 0; i < 4; ++i) frame[i] =
      static_cast<unsigned char>((size >> (8 * i)) & 0xff);
  memcpy(frame.data() + 4, json.data(), json.size());
  ResetEvent(event.get());
  operation = {};
  operation.hEvent = event.get();
  BOOL written = WriteFile(pipe, frame.data(), static_cast<DWORD>(frame.size()),
      &transferred, &operation);
  const bool okay = (written ||
      (GetLastError() == ERROR_IO_PENDING && AwaitIo(pipe, operation, stop,
          child, kBootstrapTimeoutMs, transferred))) &&
      transferred == frame.size();
  SecureZeroMemory(frame.data(), frame.size());
  return okay;
}

}  // namespace

ConsoleHostProcess::~ConsoleHostProcess() { Stop(); }

void ConsoleHostProcess::Start(const std::string& session_id,
                              const std::wstring& server_url,
                              const std::string& host_token,
                              StartResult result) {
  if (!IsUuid(session_id) || !IsHostToken(host_token) || server_url.empty()) {
    result(false, "invalid_console_start");
    return;
  }
  std::lock_guard<std::mutex> lock(mutex_);
  if (running_.load()) {
    result(session_id == session_id_, session_id == session_id_ ?
        "already_running" : "console_busy");
    return;
  }
  if (worker_.joinable()) worker_.join();
  if (stop_) CloseHandle(stop_);
  stop_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (!stop_) {
    result(false, "console_stop_event_failed");
    return;
  }
  session_id_ = session_id;
  running_.store(true);
  worker_ = std::thread(&ConsoleHostProcess::Run, this, session_id, server_url,
      host_token, std::move(result));
}

void ConsoleHostProcess::Stop(const std::string& session_id) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!session_id.empty() && session_id != session_id_) return;
  if (stop_) SetEvent(stop_);
  if (worker_.joinable()) worker_.join();
  if (stop_) CloseHandle(stop_);
  stop_ = nullptr;
  session_id_.clear();
  running_.store(false);
}

void ConsoleHostProcess::Run(const std::string& session_id,
                            const std::wstring& server_url,
                            const std::string& host_token,
                            const StartResult& result) {
  bool result_sent = false;
  auto fail = [&](const char* reason) {
    if (!result_sent) result(false, reason);
    running_.store(false);
  };
  const std::wstring app = AppPath();
  if (app.empty()) { fail("console_host_missing"); return; }
  std::string bootstrap = "{\"session_id\":" + JsonString(session_id) +
      ",\"server_url\":" + JsonString(Utf8(server_url)) +
      ",\"host_token\":" + JsonString(host_token) + "}";
  if (bootstrap.size() > kBootstrapLimit) {
    fail("console_bootstrap_too_large"); return;
  }
  // Restarts cover console-session changes and abnormal helper exits. A helper
  // which exits normally has ended its session and must never be resurrected.
  ULONGLONG restart_window = GetTickCount64();
  unsigned int restarts = 0;
  while (WaitForSingleObject(stop_, 0) == WAIT_TIMEOUT) {
    DWORD session = WTSGetActiveConsoleSessionId();
    if (session == 0xffffffff || session == 0) {
      if (!result_sent) { fail("no_console_session"); break; }
      if (WaitForSingleObject(stop_, 500) != WAIT_TIMEOUT) break;
      continue;
    }
    Handle token(SystemTokenForSession(session));
    if (!token) { fail("console_system_token_failed"); break; }
    const std::wstring pipe_name = NewPipeName();
    if (pipe_name.empty()) { fail("console_pipe_random_failed"); break; }
    SECURITY_ATTRIBUTES security = {sizeof(SECURITY_ATTRIBUTES), nullptr, FALSE};
    if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
            L"D:P(A;;GA;;;SY)", SDDL_REVISION_1,
            &security.lpSecurityDescriptor, nullptr)) {
      fail("console_pipe_acl_failed"); break;
    }
    Handle pipe(CreateNamedPipeW(pipe_name.c_str(), PIPE_ACCESS_OUTBOUND |
        FILE_FLAG_OVERLAPPED | FILE_FLAG_FIRST_PIPE_INSTANCE,
        PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT |
        PIPE_REJECT_REMOTE_CLIENTS, 1, static_cast<DWORD>(kBootstrapLimit + 4),
        0, kBootstrapTimeoutMs, &security));
    LocalFree(security.lpSecurityDescriptor);
    if (!pipe) { fail("console_pipe_failed"); break; }
    Handle job(CreateJobObjectW(nullptr, nullptr));
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = {};
    limits.BasicLimitInformation.LimitFlags =
        JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | JOB_OBJECT_LIMIT_DIE_ON_UNHANDLED_EXCEPTION;
    if (!job || !SetInformationJobObject(job.get(),
            JobObjectExtendedLimitInformation, &limits, sizeof(limits))) {
      fail("console_job_failed"); break;
    }
    LPVOID environment = nullptr;
    if (!CreateEnvironmentBlock(&environment, token.get(), FALSE)) {
      fail("console_environment_failed"); break;
    }
    std::wstring command = L"\"" + app + L"\" --service-console=" + pipe_name;
    std::wstring desktop = L"winsta0\\default";
    const std::wstring directory = app.substr(0, app.find_last_of(L"\\/"));
    STARTUPINFOW startup = {};
    startup.cb = sizeof(startup);
    startup.lpDesktop = desktop.data();
    startup.dwFlags = STARTF_USESHOWWINDOW;
    startup.wShowWindow = SW_HIDE;
    PROCESS_INFORMATION information = {};
    const BOOL created = CreateProcessAsUserW(token.get(), app.c_str(),
        command.data(), nullptr, nullptr, FALSE,
        CREATE_SUSPENDED | CREATE_UNICODE_ENVIRONMENT, environment,
        directory.c_str(), &startup, &information);
    DestroyEnvironmentBlock(environment);
    if (!created) { fail("console_spawn_failed"); break; }
    Handle child(information.hProcess);
    Handle child_thread(information.hThread);
    if (!AssignProcessToJobObject(job.get(), child.get())) {
      TerminateProcess(child.get(), ERROR_ACCESS_DENIED);
      fail("console_job_assign_failed"); break;
    }
    if (ResumeThread(child_thread.get()) == static_cast<DWORD>(-1)) {
      fail("console_resume_failed"); break;
    }
    if (!BootstrapChild(pipe.get(), child.get(), information.dwProcessId,
            stop_, bootstrap)) {
      fail("console_bootstrap_failed"); break;
    }
    pipe.Reset();
    if (!result_sent) {
      result(true, "service_host_started");
      result_sent = true;
    }
    bool session_changed = false;
    bool stopped = false;
    for (;;) {
      HANDLE waits[] = {stop_, child.get()};
      DWORD state = WaitForMultipleObjects(2, waits, FALSE, kMonitorIntervalMs);
      if (state == WAIT_OBJECT_0) { stopped = true; break; }
      if (state == WAIT_OBJECT_0 + 1 || state == WAIT_FAILED) break;
      DWORD active = WTSGetActiveConsoleSessionId();
      if (active != 0xffffffff && active != 0 && active != session) {
        session_changed = true;
        break;
      }
    }
    if (stopped) break;
    DWORD exit_code = 0;
    GetExitCodeProcess(child.get(), &exit_code);
    // Close the old job and wait for all its processes before starting another
    // host: two helpers must never control the same session concurrently.
    job.Reset();
    WaitForSingleObject(child.get(), 5000);
    if (!session_changed && exit_code == 0) break;
    const ULONGLONG now = GetTickCount64();
    if (now - restart_window >= 60000) {
      restart_window = now;
      restarts = 0;
    }
    if (++restarts > 3) break;
    if (WaitForSingleObject(stop_, 750) != WAIT_TIMEOUT) break;
  }
  SecureZeroMemory(bootstrap.data(), bootstrap.size());
  running_.store(false);
}
