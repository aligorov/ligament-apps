#ifndef RUNNER_DEBUG_LOG_H_
#define RUNNER_DEBUG_LOG_H_

#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>

namespace debug_log {

enum class Mode { gui, link_host, service_console };

struct State {
  bool enabled = false;
  std::string path;
};

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

void Initialize(Mode mode) noexcept;
State GetState() noexcept;
bool IsWorker() noexcept;
uint32_t SetEnabled(bool enabled) noexcept;
bool Write(std::string_view event, std::string_view error_type = {},
           std::string_view error_code = {},
           std::optional<int64_t> os_error = std::nullopt) noexcept;

}  // namespace debug_log

#endif  // RUNNER_DEBUG_LOG_H_
