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

DWORD Win32Failure() {
  const DWORD error = ::GetLastError();
  return error == ERROR_SUCCESS ? ERROR_GEN_FAILURE : error;
}

DWORD CheckHandle(HANDLE handle, detail::SecurityUse use, PACL repair_acl = nullptr) {
  const bool directory = use != detail::SecurityUse::log_file;
  BY_HANDLE_FILE_INFORMATION info{};
  if (!::GetFileInformationByHandle(handle, &info)) return Win32Failure();
  if ((info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) ||
      ((info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0) != directory ||
      info.nNumberOfLinks != 1) return ERROR_ACCESS_DENIED;
  if (!Worker()) return ERROR_SUCCESS;

  PSID owner = nullptr;
  PACL acl = nullptr;
  PSECURITY_DESCRIPTOR descriptor = nullptr;
  const DWORD status = ::GetSecurityInfo(handle, SE_FILE_OBJECT,
      OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
      &owner, nullptr, &acl, nullptr, &descriptor);
  LocalMemory memory;
  memory.value = descriptor;
  if (status != ERROR_SUCCESS) return status;
  SECURITY_DESCRIPTOR_CONTROL control = 0;
  DWORD revision = 0;
  if (!descriptor || !::IsValidSecurityDescriptor(descriptor) ||
      !::GetSecurityDescriptorControl(descriptor, &control, &revision) ||
      !(control & SE_DACL_PRESENT) || !acl || !::IsValidAcl(acl))
    return ERROR_INVALID_ACL;
  if (!owner || !::IsValidSid(owner)) return ERROR_INVALID_OWNER;
  std::array<BYTE, SECURITY_MAX_SID_SIZE> system_sid{};
  std::array<BYTE, SECURITY_MAX_SID_SIZE> admin_sid{};
  DWORD system_size = static_cast<DWORD>(system_sid.size());
  DWORD admin_size = static_cast<DWORD>(admin_sid.size());
  if (!::CreateWellKnownSid(WinLocalSystemSid, nullptr, system_sid.data(),
                           &system_size) ||
      !::CreateWellKnownSid(WinBuiltinAdministratorsSid, nullptr,
                           admin_sid.data(), &admin_size)) return Win32Failure();
  const bool privileged_owner = ::EqualSid(owner, system_sid.data()) ||
                                ::EqualSid(owner, admin_sid.data());
  bool private_acl = (control & SE_DACL_PROTECTED) && acl->AceCount == 2;
  bool safe_parent_acl = true;
  bool system = false;
  bool admin = false;
  static_assert(detail::kParentReadOnlyAccess ==
      (FILE_GENERIC_READ | FILE_GENERIC_EXECUTE | GENERIC_READ | GENERIC_EXECUTE));
  static_assert(detail::kFileAllAccess == FILE_ALL_ACCESS);
  static_assert(detail::kPrivateAceFlags == (OBJECT_INHERIT_ACE | CONTAINER_INHERIT_ACE));
  for (DWORD i = 0; i < acl->AceCount; ++i) {
    void* raw_ace = nullptr;
    if (!::GetAce(acl, i, &raw_ace)) return ERROR_INVALID_ACL;
    const auto* header = static_cast<const ACE_HEADER*>(raw_ace);
    // Object/callback/unknown ACEs require richer access evaluation; reject.
    if ((header->AceType != ACCESS_ALLOWED_ACE_TYPE &&
         header->AceType != ACCESS_DENIED_ACE_TYPE) ||
        (header->AceFlags & ~(OBJECT_INHERIT_ACE | CONTAINER_INHERIT_ACE |
                             NO_PROPAGATE_INHERIT_ACE | INHERIT_ONLY_ACE |
                             INHERITED_ACE))) return ERROR_INVALID_ACL;
    constexpr size_t sid_offset = offsetof(ACCESS_ALLOWED_ACE, SidStart);
    if (header->AceSize < sid_offset + 8) return ERROR_INVALID_ACL;
    const auto* ace = static_cast<const ACCESS_ALLOWED_ACE*>(raw_ace);
    PSID sid = const_cast<DWORD*>(&ace->SidStart);
    if (::GetSidLengthRequired(static_cast<SID*>(sid)->SubAuthorityCount) >
        header->AceSize - sid_offset || !::IsValidSid(sid)) return ERROR_INVALID_ACL;
    const bool is_system = ::EqualSid(sid, system_sid.data()) != FALSE;
    const bool is_admin = ::EqualSid(sid, admin_sid.data()) != FALSE;
    const bool allow = header->AceType == ACCESS_ALLOWED_ACE_TYPE;
    // Conservative: never rely on deny ordering, group membership, or denies
    // cancelling an unsafe grant. INHERIT_ONLY grants do not apply to this parent.
    if (allow && !detail::SafeParentAllow(is_system || is_admin,
            (header->AceFlags & INHERIT_ONLY_ACE) != 0, ace->Mask))
      safe_parent_acl = false;
    if (!detail::PrivateAllow(allow, ace->Mask, header->AceFlags))
      private_acl = false;
    if (is_system && !system) system = true;
    else if (is_admin && !admin) admin = true;
    else private_acl = false;
  }
  const auto decision = detail::DecideSecurity(use, true, privileged_owner,
      safe_parent_acl, private_acl && system && admin);
  if (decision == detail::SecurityDecision::accept) return ERROR_SUCCESS;
  if (decision != detail::SecurityDecision::tighten || !repair_acl)
    return ERROR_ACCESS_DENIED;
  // Only Logs is repairable. Keep its verified owner; never touch the parent,
  // files or descendants. The caller pins this object with MAXIMUM_ALLOWED,
  // which prevents SetSecurityInfo from propagating ACEs to existing children.
  const DWORD repair = ::SetSecurityInfo(handle, SE_FILE_OBJECT,
      DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION,
      nullptr, nullptr, repair_acl, nullptr);
  if (repair != ERROR_SUCCESS) return repair;
  return CheckHandle(handle, use);  // Revalidate the same handle after tightening.
}

DWORD WriteAll(HANDLE file, const char* data, DWORD size) {
  while (size != 0) {
    DWORD written = 0;
    if (!::WriteFile(file, data, size, &written, nullptr)) return Win32Failure();
    if (written == 0) return ERROR_WRITE_FAULT;
    data += written;
    size -= written;
  }
  return ERROR_SUCCESS;
}

DWORD Seek(HANDLE file, LONGLONG position) {
  LARGE_INTEGER offset{};
  offset.QuadPart = position;
  return ::SetFilePointerEx(file, offset, nullptr, FILE_BEGIN)
      ? ERROR_SUCCESS : Win32Failure();
}

DWORD Rotate(HANDLE current, const std::wstring& path,
             SECURITY_ATTRIBUTES* security, LONGLONG size) {
  Handle backup(::CreateFileW((path + L".1").c_str(),
      GENERIC_READ | GENERIC_WRITE | READ_CONTROL, 0, security, OPEN_ALWAYS,
      FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
  if (!backup) return Win32Failure();
  DWORD status = CheckHandle(backup.value, detail::SecurityUse::log_file);
  if (status != ERROR_SUCCESS) return status;
  status = Seek(backup.value, 0);
  if (status != ERROR_SUCCESS) return status;
  if (!::SetEndOfFile(backup.value)) return Win32Failure();
  status = Seek(current, size > kMaxBytes ? size - kMaxBytes : 0);
  if (status != ERROR_SUCCESS) return status;
  std::array<char, 16 * 1024> buffer{};
  LONGLONG remaining = size > kMaxBytes ? kMaxBytes : size;
  while (remaining > 0) {
    const DWORD wanted = static_cast<DWORD>(
        remaining < static_cast<LONGLONG>(buffer.size()) ? remaining : buffer.size());
    DWORD read = 0;
    if (!::ReadFile(current, buffer.data(), wanted, &read, nullptr)) return Win32Failure();
    if (read == 0) return ERROR_READ_FAULT;
    status = WriteAll(backup.value, buffer.data(), read);
    if (status != ERROR_SUCCESS) return status;
    remaining -= read;
  }
  if (!::FlushFileBuffers(backup.value)) return Win32Failure();
  status = Seek(current, 0);
  if (status != ERROR_SUCCESS) return status;
  return ::SetEndOfFile(current) ? ERROR_SUCCESS : Win32Failure();
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

DWORD Append(std::string_view event, std::string_view error_type = {},
             std::string_view error_code = {},
             std::optional<int64_t> os_error = std::nullopt,
             std::string_view context = {}) {
  if (base_path.empty() || log_path.empty()) return ERROR_PATH_NOT_FOUND;
  LocalMemory descriptor;
  SECURITY_ATTRIBUTES attributes{};
  SECURITY_ATTRIBUTES* security = nullptr;
  PACL repair_acl = nullptr;
  if (Worker()) {
    PSECURITY_DESCRIPTOR raw = nullptr;
    if (!::ConvertStringSecurityDescriptorToSecurityDescriptorW(
        L"O:SYG:SYD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)", SDDL_REVISION_1,
        &raw, nullptr)) return Win32Failure();
    descriptor.value = raw;
    BOOL present = FALSE;
    BOOL defaulted = FALSE;
    if (!::GetSecurityDescriptorDacl(raw, &present, &repair_acl, &defaulted) ||
        !present || !repair_acl) return ERROR_INVALID_ACL;
    attributes.nLength = sizeof(attributes);
    attributes.lpSecurityDescriptor = raw;
    security = &attributes;
  }
  const std::wstring app = base_path + L"\\Ligament";
  const std::wstring directory = app + L"\\Logs";
  if (!::CreateDirectoryW(app.c_str(), security) &&
      ::GetLastError() != ERROR_ALREADY_EXISTS) return Win32Failure();
  Handle app_handle(::CreateFileW(app.c_str(), FILE_READ_ATTRIBUTES | READ_CONTROL,
      FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING,
      FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
  if (!app_handle) return Win32Failure();
  DWORD status = CheckHandle(app_handle.value, detail::SecurityUse::parent);
  if (status != ERROR_SUCCESS) return status;
  if (!::CreateDirectoryW(directory.c_str(), security) &&
      ::GetLastError() != ERROR_ALREADY_EXISTS) return Win32Failure();
  // MAXIMUM_ALLOWED suppresses ACL propagation to unverified children during
  // repair. No FILE_SHARE_DELETE: keep both checked directories pinned to paths.
  Handle directory_handle(::CreateFileW(directory.c_str(),
      Worker() ? MAXIMUM_ALLOWED : FILE_READ_ATTRIBUTES | READ_CONTROL,
      FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING,
      FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
  if (!directory_handle) return Win32Failure();
  status = CheckHandle(directory_handle.value, detail::SecurityUse::log_directory,
                       repair_acl);
  if (status != ERROR_SUCCESS) return status;
  // The exclusive current-file handle serializes writes and rotation.
  Handle current(::CreateFileW(log_path.c_str(),
      GENERIC_READ | GENERIC_WRITE | READ_CONTROL, 0, security, OPEN_ALWAYS,
      FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
  if (!current) return Win32Failure();
  status = CheckHandle(current.value, detail::SecurityUse::log_file);
  if (status != ERROR_SUCCESS) return status;
  LARGE_INTEGER size{};
  const std::string line = Line(event, error_type, error_code, os_error, context);
  if (line.empty() || line.size() > static_cast<size_t>(kMaxBytes)) return ERROR_INVALID_DATA;
  if (!::GetFileSizeEx(current.value, &size)) return Win32Failure();
  if (size.QuadPart > kMaxBytes - static_cast<LONGLONG>(line.size())) {
    status = Rotate(current.value, log_path, security, size.QuadPart);
  } else {
    status = Seek(current.value, size.QuadPart);
  }
  if (status != ERROR_SUCCESS) return status;
  status = WriteAll(current.value, line.data(), static_cast<DWORD>(line.size()));
  if (status != ERROR_SUCCESS) return status;
  return ::FlushFileBuffers(current.value) ? ERROR_SUCCESS : Win32Failure();
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
    file_name = mode == Mode::gui ? L"app-debug.log" : L"link-debug.log";
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
  LastErrorGuard error;
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
    // A log write failure must not misreport an already persisted toggle.
    try {
      if (enabled && ReadEnabled()) Append("debug.enabled");
      else if (!enabled && previously_enabled) Append("debug.disabled");
    } catch (...) {}
    return ERROR_SUCCESS;
  } catch (...) { return ERROR_NOT_ENOUGH_MEMORY; }
}

bool Write(std::string_view event, std::string_view error_type,
           std::string_view error_code, std::optional<int64_t> os_error,
           std::string_view context, uint32_t* diagnostic_code) noexcept {
  LastErrorGuard error;
  const auto result = [diagnostic_code](DWORD status) {
    if (diagnostic_code) *diagnostic_code = status;
    return status == ERROR_SUCCESS;
  };
  if (!ValidEvent(event) ||
      (!error_type.empty() && !ValidErrorType(error_type)) ||
      (!error_code.empty() && !ValidErrorCode(error_code)) ||
      !ValidContext(context)) return result(ERROR_INVALID_PARAMETER);
  try {
    std::lock_guard<std::mutex> lock(log_mutex);
    if (!ReadEnabled()) return result(ERROR_NOT_READY);
    return result(Append(event, error_type, error_code, os_error, context));
  } catch (...) { return result(ERROR_NOT_ENOUGH_MEMORY); }
}
}  // namespace debug_log
