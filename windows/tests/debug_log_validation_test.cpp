#include "../runner/debug_log.h"

#include <cassert>
#include <string>
#include <string_view>

int main() {
  using namespace debug_log;
  static_assert(ValidEvent("startup.mode.link_host"));
  static_assert(!ValidEvent("Startup"));
  static_assert(!ValidEvent(""));
  assert(ValidEvent(std::string(80, 'a')));
  assert(!ValidEvent(std::string(81, 'a')));
  assert(ValidErrorType(std::string(64, 'A')));
  assert(!ValidErrorType(std::string(65, 'A')));
  assert(ValidErrorCode(std::string(64, 'A')));
  assert(!ValidErrorCode(std::string(65, 'A')));
  for (int c = 0; c < 256; ++c) {
    const char byte = static_cast<char>(c);
    const std::string_view field(&byte, 1);
    const bool lower = c >= 'a' && c <= 'z';
    const bool upper = c >= 'A' && c <= 'Z';
    const bool digit = c >= '0' && c <= '9';
    const bool common = lower || digit || c == '_' || c == '.';
    assert(ValidEvent(field) == (common || c == '-'));
    assert(ValidErrorType(field) == (common || upper));
    assert(ValidErrorCode(field) == (common || upper || c == '-'));
  }
  for (const auto* raw : {"startup\nsecret", "event=payload", "a b", "a/b",
                          "C:\\Users\\private", "ligament://secret", "abc+def"}) {
    assert(!ValidEvent(raw));
    assert(!ValidErrorType(raw));
    assert(!ValidErrorCode(raw));
  }
  assert(!ValidEvent(std::string_view("a\0b", 3)));
}
