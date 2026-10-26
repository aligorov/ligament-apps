#include "debug_log.h"

#include <windows.h>
#include <aclapi.h>
#include <sddl.h>
#include <shlobj.h>
#include <wtsapi32.h>

#include <array>
#include <climits>
#include <cstdio>
#include <mutex>
#include <vector>

namespace debug_log {
namespace {
constexpr wchar_t kSettingsKey[] = L"Software\\Ligament\\2FA";
constexpr wchar_t kSetting[] = L"DebugLogsEnabled";
constexpr LONGLONG kMaxBytes = 2 * 1024 * 1024;
std::mutex log_mutex;
Mode log_mode = Mode::gui;
bool initialized = false;
std::wstring base_path;
std::wstring file_name;
std::wstring log_path;

struct LastErrorGuard {
  DWORD error = ::GetLastError();
  ~LastErrorGuard() { ::SetLastError(error); }
};

struct Handle {
  HANDLE value = INVALID_HANDLE_VALUE;
  explicit Handle(HANDLE handle) : value(handle) {}
  ~Handle() {
    if (value != INVALID_HANDLE_VALUE && value != nullptr) ::CloseHandle(value);
  }
  Handle(const Handle&) = delete;
  Handle& operator=(const Handle&) = delete;
  explicit operator bool() const {
    return value != INVALID_HANDLE_VALUE && value != nullptr;
  }
};

struct LocalMemory {
  HLOCAL value = nullptr;
  ~LocalMemory() { if (value) ::LocalFree(value); }
};

struct TaskMemory {
  PWSTR value = nullptr;
  ~TaskMemory() { ::CoTaskMemFree(value); }
};

struct RegistryKey {
  HKEY value = nullptr;
  ~RegistryKey() { if (value) ::RegCloseKey(value); }
};

bool Worker() { return log_mode != Mode::gui; }

std::string Utf8(const std::wstring& value) {
  if (value.empty() || value.size() > INT_MAX) return {};
  const int length = static_cast<int>(value.size());
  const int bytes = ::WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
      value.data(), length, nullptr, 0, nullptr, nullptr);
  if (bytes <= 0) return {};
  std::string result(static_cast<size_t>(bytes), '\0');
  if (::WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(), length,
      result.data(), bytes, nullptr, nullptr) != bytes) return {};
  return result;
}

bool ReadRegistry(HKEY root, const std::wstring& key) {
  DWORD enabled = 0;
  DWORD size = sizeof(enabled);
  return ::RegGetValueW(root, key.c_str(), kSetting, RRF_RT_REG_DWORD,
                       nullptr, &enabled, &size) == ERROR_SUCCESS && enabled == 1;
}

bool ReadEnabled() {
  if (!initialized) return false;
  if (!Worker()) return ReadRegistry(HKEY_CURRENT_USER, kSettingsKey);
  DWORD session = 0;
  HANDLE raw_token = nullptr;
  if (!::ProcessIdToSessionId(::GetCurrentProcessId(), &session) ||
      !::WTSQueryUserToken(session, &raw_token)) return false;
  Handle token(raw_token);
  DWORD bytes = 0;
  ::GetTokenInformation(token.value, TokenUser, nullptr, 0, &bytes);
  if (bytes == 0 || bytes > 64 * 1024) return false;
  std::vector<BYTE> buffer(bytes);
  if (!::GetTokenInformation(token.value, TokenUser, buffer.data(), bytes,
                            &bytes)) return false;
  const auto* user = reinterpret_cast<const TOKEN_USER*>(buffer.data());
  LPWSTR sid = nullptr;
  if (!::ConvertSidToStringSidW(user->User.Sid, &sid)) return false;
  LocalMemory sid_memory;
  sid_memory.value = sid;
  return ReadRegistry(HKEY_USERS, std::wstring(sid) + L"\\" + kSettingsKey);
}

bool ProtectedSecurity(HANDLE handle) {
  PSID owner = nullptr;
  PACL acl = nullptr;
  PSECURITY_DESCRIPTOR descriptor = nullptr;
  if (::GetSecurityInfo(handle, SE_FILE_OBJECT,
      OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
      &owner, nullptr, &acl, nullptr, &descriptor) != ERROR_SUCCESS) return false;
  LocalMemory memory;
  memory.value = descriptor;
  SECURITY_DESCRIPTOR_CONTROL control = 0;
  DWORD revision = 0;
  if (!::GetSecurityDescriptorControl(descriptor, &control, &revision) ||
      !(control & SE_DACL_PROTECTED) || !acl || acl->AceCount != 2) return false;
  std::array<BYTE, SECURITY_MAX_SID_SIZE> system_sid{};
  std::array<BYTE, SECURITY_MAX_SID_SIZE> admin_sid{};
  DWORD system_size = static_cast<DWORD>(system_sid.size());
  DWORD admin_size = static_cast<DWORD>(admin_sid.size());
  if (!::CreateWellKnownSid(WinLocalSystemSid, nullptr, system_sid.data(),
                           &system_size) ||
      !::CreateWellKnownSid(WinBuiltinAdministratorsSid, nullptr,
                           admin_sid.data(), &admin_size)) return false;
  if (!owner || (!::EqualSid(owner, system_sid.data()) &&
                 !::EqualSid(owner, admin_sid.data()))) return false;
  bool system = false;
  bool admin = false;
  for (DWORD i = 0; i < acl->AceCount; ++i) {
    void* raw_ace = nullptr;
    if (!::GetAce(acl, i, &raw_ace)) return false;
    const auto* ace = static_cast<const ACCESS_ALLOWED_ACE*>(raw_ace);
    if (ace->Header.AceType != ACCESS_ALLOWED_ACE_TYPE ||
        ace->Mask != FILE_ALL_ACCESS) return false;
    PSID sid = const_cast<DWORD*>(&ace->SidStart);
    if (::EqualSid(sid, system_sid.data()) && !system) system = true;
    else if (::EqualSid(sid, admin_sid.data()) && !admin) admin = true;
    else return false;
  }
  return system && admin;
}

bool SafeHandle(HANDLE handle, bool directory) {
  BY_HANDLE_FILE_INFORMATION info{};
  if (!::GetFileInformationByHandle(handle, &info) ||
      (info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) ||
      ((info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0) != directory)
    return false;
  if (!directory && info.nNumberOfLinks != 1) return false;
  return !Worker() || ProtectedSecurity(handle);
}

bool WriteAll(HANDLE file, const char* data, DWORD size) {
  while (size != 0) {
    DWORD written = 0;
    if (!::WriteFile(file, data, size, &written, nullptr) || written == 0)
      return false;
    data += written;
    size -= written;
  }
  return true;
}

bool Seek(HANDLE file, LONGLONG position) {
  LARGE_INTEGER offset{};
  offset.QuadPart = position;
  return ::SetFilePointerEx(file, offset, nullptr, FILE_BEGIN) != FALSE;
}

bool Rotate(HANDLE current, const std::wstring& path,
            SECURITY_ATTRIBUTES* security, LONGLONG size) {
  Handle backup(::CreateFileW((path + L".1").c_str(),
      GENERIC_READ | GENERIC_WRITE | READ_CONTROL, 0, security, OPEN_ALWAYS,
      FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
  if (!backup || !SafeHandle(backup.value, false) ||
      !Seek(backup.value, 0) || !::SetEndOfFile(backup.value) ||
      !Seek(current, size > kMaxBytes ? size - kMaxBytes : 0)) return false;
  std::array<char, 16 * 1024> buffer{};
  LONGLONG remaining = size > kMaxBytes ? kMaxBytes : size;
  while (remaining > 0) {
    const DWORD wanted = static_cast<DWORD>(
        remaining < static_cast<LONGLONG>(buffer.size()) ? remaining : buffer.size());
    DWORD read = 0;
    if (!::ReadFile(current, buffer.data(), wanted, &read, nullptr) || read == 0 ||
        !WriteAll(backup.value, buffer.data(), read)) return false;
    remaining -= read;
  }
  return ::FlushFileBuffers(backup.value) && Seek(current, 0) &&
         ::SetEndOfFile(current);
}

std::string Line(std::string_view event, std::string_view error_type,
                 std::string_view error_code, std::optional<int64_t> os_error,
                 std::string_view context) {
  SYSTEMTIME now{};
  ::GetLocalTime(&now);
  TIME_ZONE_INFORMATION zone{};
  const DWORD zone_state = ::GetTimeZoneInformation(&zone);
  if (zone_state == TIME_ZONE_ID_INVALID) return {};
  LONG bias = zone.Bias;
  if (zone_state == TIME_ZONE_ID_DAYLIGHT) bias += zone.DaylightBias;
  else if (zone_state == TIME_ZONE_ID_STANDARD) bias += zone.StandardBias;
  const LONG offset = -bias;
  const LONG absolute = offset < 0 ? -offset : offset;
  char prefix[160]{};
  const int count = std::snprintf(prefix, sizeof(prefix),
      "%04u-%02u-%02uT%02u:%02u:%02u.%03u%c%02ld:%02ld pid=%lu tid=%lu event=",
      static_cast<unsigned>(now.wYear), static_cast<unsigned>(now.wMonth),
      static_cast<unsigned>(now.wDay), static_cast<unsigned>(now.wHour),
      static_cast<unsigned>(now.wMinute), static_cast<unsigned>(now.wSecond),
      static_cast<unsigned>(now.wMilliseconds), offset < 0 ? '-' : '+',
      absolute / 60, absolute % 60, ::GetCurrentProcessId(), ::GetCurrentThreadId());
  if (count <= 0 || static_cast<size_t>(count) >= sizeof(prefix)) return {};
  std::string line(prefix, static_cast<size_t>(count));
  line.append(event.data(), event.size());
#ifdef FLUTTER_VERSION
  constexpr std::string_view version = FLUTTER_VERSION;
  bool safe_version = !version.empty() && version.size() <= 64;
  for (const char c : version) {
    if (c != '+' && !ValidField(std::string_view(&c, 1), 1, true, true)) {
      safe_version = false;
      break;
    }
  }
  if (safe_version) {
    line += " version=";
    line.append(version.data(), version.size());
  }
#endif
  if (!error_type.empty()) {
    line += " error_type=";
    line.append(error_type.data(), error_type.size());
  }
  if (!error_code.empty()) {
    line += " error_code=";
    line.append(error_code.data(), error_code.size());
  }
  if (os_error) line += " os_error=" + std::to_string(*os_error);
  if (!context.empty()) {
    line += " ";
    line.append(context.data(), context.size());
  }
  line += "\r\n";
  return line;
}

bool Append(std::string_view event, std::string_view error_type = {},
            std::string_view error_code = {},
            std::optional<int64_t> os_error = std::nullopt,
            std::string_view context = {}) {
  if (base_path.empty() || log_path.empty()) return false;
  LocalMemory descriptor;
  SECURITY_ATTRIBUTES attributes{};
  SECURITY_ATTRIBUTES* security = nullptr;
  if (Worker()) {
    PSECURITY_DESCRIPTOR raw = nullptr;
    if (!::ConvertStringSecurityDescriptorToSecurityDescriptorW(
        L"O:SYG:SYD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)", SDDL_REVISION_1,
        &raw, nullptr)) return false;
    descriptor.value = raw;
    attributes.nLength = sizeof(attributes);
    attributes.lpSecurityDescriptor = raw;
    security = &attributes;
  }
  const std::wstring app = base_path + L"\\Ligament";
  const std::wstring directory = app + L"\\Logs";
  if (!::CreateDirectoryW(app.c_str(), security) &&
      ::GetLastError() != ERROR_ALREADY_EXISTS) return false;
  Handle app_handle(::CreateFileW(app.c_str(), FILE_READ_ATTRIBUTES | READ_CONTROL,
      FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING,
      FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
  if (!app_handle || !SafeHandle(app_handle.value, true)) return false;
  if (!::CreateDirectoryW(directory.c_str(), security) &&
      ::GetLastError() != ERROR_ALREADY_EXISTS) return false;
  Handle directory_handle(::CreateFileW(directory.c_str(),
      FILE_READ_ATTRIBUTES | READ_CONTROL, FILE_SHARE_READ | FILE_SHARE_WRITE,
      nullptr, OPEN_EXISTING,
      FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
  if (!directory_handle || !SafeHandle(directory_handle.value, true)) return false;
  // The exclusive current-file handle serializes writes and rotation.
  Handle current(::CreateFileW(log_path.c_str(),
      GENERIC_READ | GENERIC_WRITE | READ_CONTROL, 0, security, OPEN_ALWAYS,
      FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
  if (!current || !SafeHandle(current.value, false)) return false;
  LARGE_INTEGER size{};
  const std::string line = Line(event, error_type, error_code, os_error, context);
  if (line.empty() || line.size() > static_cast<size_t>(kMaxBytes) ||
      !::GetFileSizeEx(current.value, &size)) return false;
  if (size.QuadPart > kMaxBytes - static_cast<LONGLONG>(line.size())) {
    if (!Rotate(current.value, log_path, security, size.QuadPart)) return false;
  } else if (!Seek(current.value, size.QuadPart)) return false;
  return WriteAll(current.value, line.data(), static_cast<DWORD>(line.size())) &&
         ::FlushFileBuffers(current.value);
}
}  // namespace

void Initialize(Mode mode) noexcept {
  LastErrorGuard error;
  try {
    std::lock_guard<std::mutex> lock(log_mutex);
    log_mode = mode;
    initialized = true;
    base_path.clear();
    log_path.clear();
    file_name = mode == Mode::gui ? L"app-debug.log" :
        mode == Mode::link_host ? L"link-debug.log" : L"console-debug.log";
    TaskMemory path;
    if (SUCCEEDED(::SHGetKnownFolderPath(Worker() ? FOLDERID_ProgramData :
        FOLDERID_LocalAppData, KF_FLAG_DEFAULT, nullptr, &path.value)) && path.value) {
      base_path = path.value;
      log_path = base_path + L"\\Ligament\\Logs\\" + file_name;
    }
  } catch (...) {}
}

State GetState() noexcept {
  LastErrorGuard error;
  try {
    std::lock_guard<std::mutex> lock(log_mutex);
    return {ReadEnabled(), Utf8(log_path)};
  } catch (...) { return {}; }
}

bool IsWorker() noexcept {
  try {
    std::lock_guard<std::mutex> lock(log_mutex);
    return Worker();
  } catch (...) { return true; }
}

uint32_t SetEnabled(bool enabled) noexcept {
  LastErrorGuard error;
  try {
    std::lock_guard<std::mutex> lock(log_mutex);
    if (!initialized || Worker()) return ERROR_ACCESS_DENIED;
    RegistryKey key;
    LSTATUS status = ::RegCreateKeyExW(HKEY_CURRENT_USER, kSettingsKey, 0,
        nullptr, REG_OPTION_NON_VOLATILE, KEY_SET_VALUE, nullptr,
        &key.value, nullptr);
    if (status != ERROR_SUCCESS) return static_cast<uint32_t>(status);
    const bool previously_enabled = ReadEnabled();
    const DWORD value = enabled ? 1 : 0;
    status = ::RegSetValueExW(key.value, kSetting, 0, REG_DWORD,
        reinterpret_cast<const BYTE*>(&value), sizeof(value));
    if (status != ERROR_SUCCESS) return static_cast<uint32_t>(status);
    // The final off event uses the pre-toggle state only in the GUI.
    try {
      if (enabled && ReadEnabled()) Append("debug.enabled");
      else if (!enabled && previously_enabled) Append("debug.disabled");
    } catch (...) {}
    return ERROR_SUCCESS;
  } catch (...) { return ERROR_NOT_ENOUGH_MEMORY; }
}

bool Write(std::string_view event, std::string_view error_type,
           std::string_view error_code, std::optional<int64_t> os_error,
           std::string_view context) noexcept {
  LastErrorGuard error;
  if (!ValidEvent(event) ||
      (!error_type.empty() && !ValidErrorType(error_type)) ||
      (!error_code.empty() && !ValidErrorCode(error_code)) ||
      !ValidContext(context)) return false;
  try {
    std::lock_guard<std::mutex> lock(log_mutex);
    if (!ReadEnabled()) return false;
    return Append(event, error_type, error_code, os_error, context);
  } catch (...) { return false; }
}
}  // namespace debug_log
