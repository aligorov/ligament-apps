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
  static_assert(ValidContext(""));
  static_assert(ValidContext("request_id=17 method=POST route=/api/v1/app/link/sessions/{id}/signal server=2fa.example.test:8443 http_status=403 duration_ms=250 reason=access_denied connected=false"));
  static_assert(ValidContext("session_id=10000000-0000-4000-8000-000000000001 origin=host_answer frame_ready=false queue_bytes=4096 rtt_ms=2.5"));
  static_assert(!ValidContext("token=private-token"));
  static_assert(!ValidContext("password=private-password"));
  static_assert(!ValidContext("route=/api/v1/app/login?token=private-token"));
  static_assert(!ValidContext("server=user:private-password@host"));
  static_assert(!ValidContext("method=captureScreen"));
  static_assert(!ValidContext("duration_ms=NaN"));
  static_assert(!ValidContext("duration_ms=1e5"));
  static_assert(!ValidContext("duration_ms=-"));
  static_assert(!ValidContext("duration_ms=1."));
  static_assert(!ValidContext("connected=1"));
  static_assert(!ValidContext("session_id=not-a-uuid"));
  static_assert(!ValidContext("reason=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"));
  static_assert(!ValidContext("reason=host_failed\nclipboard=private-text"));
  static_assert(!ValidContext("count=1 "));
  static_assert(!ValidContext(" count=1"));
  static_assert(!ValidContext("count=1  count=2"));
  std::string context;
  for (int i = 0; i < 64; ++i) {
    if (!context.empty()) context += ' ';
    context += "count=1";
  }
  assert(ValidContext(context));
  assert(!ValidContext(context + " count=1"));
  assert(!ValidContext("route=/" + std::string(240, 'a')));
  assert(!ValidContext("server=" + std::string(254, 'a')));
  assert(!ValidContext(std::string(4097, 'a')));
}
