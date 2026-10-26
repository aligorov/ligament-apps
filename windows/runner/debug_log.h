#ifndef RUNNER_DEBUG_LOG_H_
#define RUNNER_DEBUG_LOG_H_

#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>

namespace debug_log {

enum class Mode { gui, link_host };

struct State {
  bool enabled = false;
  std::string path;
};

namespace detail {
// Win32 FILE_GENERIC_READ | FILE_GENERIC_EXECUTE, plus their generic forms.
// All other bits (including unknown rights) fail closed for untrusted trustees.
constexpr uint32_t kParentReadOnlyAccess = 0x001200a9u | 0xa0000000u;
constexpr bool SafeParentAllow(bool privileged, bool inherit_only,
                               uint32_t access) noexcept {
  return privileged || inherit_only || (access & ~kParentReadOnlyAccess) == 0;
}

constexpr uint32_t kFileAllAccess = 0x001f01ffu;
constexpr uint8_t kPrivateAceFlags = 0x03u;  // Object/container inherit only.
constexpr bool PrivateAllow(bool allow, uint32_t access, uint8_t flags) noexcept {
  return allow && access == kFileAllAccess && (flags & ~kPrivateAceFlags) == 0;
}

enum class SecurityUse { parent, log_directory, log_file };
enum class SecurityDecision { reject, accept, tighten };

constexpr SecurityDecision DecideSecurity(SecurityUse use, bool safe_object,
    bool privileged_owner, bool safe_parent_acl, bool private_acl) noexcept {
  if (!safe_object || !privileged_owner) return SecurityDecision::reject;
  if (use == SecurityUse::parent) {
    return safe_parent_acl ? SecurityDecision::accept : SecurityDecision::reject;
  }
  if (private_acl) return SecurityDecision::accept;
  // Do not repair writable/ambiguous ACLs: previously granted write handles
  // survive DACL changes. Never repair files (including hardlinked files).
  return use == SecurityUse::log_directory && safe_parent_acl
      ? SecurityDecision::tighten : SecurityDecision::reject;
}
}  // namespace detail

constexpr bool ValidField(std::string_view value, std::size_t limit,
                          bool uppercase, bool hyphen) noexcept {
  if (value.empty() || value.size() > limit) return false;
  for (const char c : value) {
    if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') ||
        c == '_' || c == '.' || (uppercase && c >= 'A' && c <= 'Z') ||
        (hyphen && c == '-')) continue;
    return false;
  }
  return true;
}

constexpr bool ValidEvent(std::string_view value) noexcept {
  return ValidField(value, 80, false, true);
}
constexpr bool ValidErrorType(std::string_view value) noexcept {
  return ValidField(value, 64, true, false);
}
constexpr bool ValidErrorCode(std::string_view value) noexcept {
  return ValidField(value, 64, true, true);
}

template <std::size_t N>
constexpr bool OneOf(std::string_view value, const std::string_view (&values)[N]) noexcept {
  for (const auto candidate : values) if (candidate == value) return true;
  return false;
}

constexpr bool ValidNumber(std::string_view value) noexcept {
  if (value.empty() || value.size() > 32) return false;
  std::size_t i = value.front() == '-' ? 1 : 0;
  bool digit = false;
  bool dot = false;
  for (; i < value.size(); ++i) {
    const char c = value[i];
    if (c >= '0' && c <= '9') digit = true;
    else if (c == '.' && !dot && digit && i + 1 < value.size()) dot = true;
    else return false;
  }
  return digit;
}

constexpr bool ValidUuid(std::string_view value) noexcept {
  if (value.size() != 36) return false;
  for (std::size_t i = 0; i < value.size(); ++i) {
    if (i == 8 || i == 13 || i == 18 || i == 23) {
      if (value[i] != '-') return false;
    } else if (!((value[i] >= '0' && value[i] <= '9') ||
                 (value[i] >= 'a' && value[i] <= 'f') ||
                 (value[i] >= 'A' && value[i] <= 'F'))) return false;
  }
  return true;
}

constexpr bool LooksLikeSecret(std::string_view value) noexcept {
  if (value.size() < 32) return false;
  for (const char c : value) {
    if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') ||
          (c >= 'A' && c <= 'F'))) return false;
  }
  return true;
}

constexpr bool ValidContextValue(std::string_view key, std::string_view value) noexcept {
  constexpr std::string_view numbers[] = {
      "request_id", "attempt", "duration_ms", "elapsed_ms", "count", "bytes",
      "response_bytes", "sent_bytes", "received_bytes", "width", "height",
      "frames", "rtt_ms", "queue_bytes", "acked_seq", "seq", "cursor",
      "ice_servers", "candidates", "tracks", "timeout_ms", "code", "http_status"};
  constexpr std::string_view booleans[] = {
      "connected", "frame_ready", "control_ready", "owner", "recorder_enabled",
      "mandatory", "first_frame_acked"};
  constexpr std::string_view labels[] = {
      "phase", "origin", "reason", "state", "ice_state", "pc_state", "dc_state",
      "message_type", "transport", "operation", "result"};
  constexpr std::string_view methods[] = {"GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"};
  if (OneOf(key, numbers)) return ValidNumber(value);
  if (OneOf(key, booleans)) return value == "true" || value == "false";
  if (key == "session_id" || key == "agent_id") return ValidUuid(value);
  if (OneOf(key, labels)) return ValidErrorCode(value) && !LooksLikeSecret(value);
  if (key == "method") return OneOf(value, methods);
  if (key == "server") {
    if (value.empty() || value.size() > 253) return false;
    for (const char c : value) {
      if (!ValidField(std::string_view(&c, 1), 1, true, true) &&
          c != '[' && c != ']' && c != ':') return false;
    }
    return true;
  }
  if (key == "route") {
    if (value.empty() || value.front() != '/' || value.size() > 240) return false;
    for (const char c : value) {
      if (!ValidField(std::string_view(&c, 1), 1, true, true) &&
          c != '/' && c != '{' && c != '}' && c != ':') return false;
    }
    return true;
  }
  return false;
}

constexpr bool ValidContext(std::string_view context) noexcept {
  if (context.size() > 4096) return false;
  std::size_t fields = 0;
  while (!context.empty()) {
    if (++fields > 64) return false;
    const auto space = context.find(' ');
    const auto token = context.substr(0, space);
    const auto equal = token.find('=');
    if (equal == std::string_view::npos ||
        !ValidContextValue(token.substr(0, equal), token.substr(equal + 1))) return false;
    if (space == std::string_view::npos) return true;
    context.remove_prefix(space + 1);
    if (context.empty()) return false;
  }
  return true;
}

void Initialize(Mode mode) noexcept;
State GetState() noexcept;
bool IsWorker() noexcept;
uint32_t SetEnabled(bool enabled) noexcept;
// Optional Win32 diagnostic code; GetLastError() is preserved on every path.
// ERROR_NOT_READY means logging is disabled or has not been initialized.
bool Write(std::string_view event, std::string_view error_type = {},
           std::string_view error_code = {},
           std::optional<int64_t> os_error = std::nullopt,
           std::string_view context = {},
           uint32_t* diagnostic_code = nullptr) noexcept;

}  // namespace debug_log

#endif  // RUNNER_DEBUG_LOG_H_
