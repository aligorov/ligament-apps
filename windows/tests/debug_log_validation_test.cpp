#include "../runner/debug_log.h"

#include <cassert>
#include <string>
#include <string_view>

int main() {
  using namespace debug_log;
  using detail::DecideSecurity;
  using detail::SafeParentAllow;
  using detail::SecurityDecision;
  using detail::SecurityUse;
  static_assert(SafeParentAllow(false, false, 0x001200a9u));  // Read/execute.
  static_assert(SafeParentAllow(false, false, 0xa0000000u));  // Generic read/execute.
  static_assert(SafeParentAllow(true, false, 0x001f01ffu));   // SYSTEM/Admin full.
  static_assert(SafeParentAllow(false, true, 0x001f01ffu));   // Inherit-only, not effective.
  for (unsigned bit = 0; bit < 32; ++bit) {
    const uint32_t access = uint32_t{1} << bit;
    const bool read_only = (access & detail::kParentReadOnlyAccess) != 0;
    assert(SafeParentAllow(false, false, access) == read_only);
    assert(SafeParentAllow(false, false, access | 0x001200a9u) == read_only);
  }
  for (const uint32_t access : {0x2u, 0x4u, 0x10u, 0x40u, 0x100u, 0x10000u,
                                0x40000u, 0x80000u, 0x40000000u, 0x10000000u,
                                0x01000000u, 0x02000000u, 0xffffffffu}) {
    // Create/write data, EA, delete-child, attributes, delete, ACL/owner,
    // generic write/all, system security, maximum allowed and unknown rights.
    assert(!SafeParentAllow(false, false, access));
  }
  for (unsigned flags = 0; flags < 256; ++flags) {
    const auto ace_flags = static_cast<uint8_t>(flags);
    // Private ACEs must be effective, explicit allows. Denies, inherit-only,
    // inherited, no-propagate and unknown flags cannot satisfy the exact DACL.
    assert(detail::PrivateAllow(true, 0x001f01ffu, ace_flags) == (flags <= 3));
    assert(!detail::PrivateAllow(false, 0x001f01ffu, ace_flags));
    assert(!detail::PrivateAllow(true, 0x001200a9u, ace_flags));
  }
  for (const auto use : {SecurityUse::parent, SecurityUse::log_directory,
                         SecurityUse::log_file}) {
    for (const bool safe_acl : {false, true}) {
      for (const bool private_acl : {false, true}) {
        // Wrong object type, reparse/hardlink or untrusted owner: never repair.
        assert(DecideSecurity(use, false, true, safe_acl, private_acl) ==
               SecurityDecision::reject);
        assert(DecideSecurity(use, true, false, safe_acl, private_acl) ==
               SecurityDecision::reject);
      }
    }
  }
  static_assert(DecideSecurity(SecurityUse::parent, true, true, true, false) ==
                SecurityDecision::accept);  // Privileged parent with user read ACEs.
  static_assert(DecideSecurity(SecurityUse::parent, true, true, false, false) ==
                SecurityDecision::reject);  // Never rewrite an unsafe parent.
  static_assert(DecideSecurity(SecurityUse::log_directory, true, true, true, false) ==
                SecurityDecision::tighten); // Legacy read-only/inherited Logs ACL.
  static_assert(DecideSecurity(SecurityUse::log_directory, true, true, false, false) ==
                SecurityDecision::reject);  // Unsafe grants/retained write handles.
  static_assert(DecideSecurity(SecurityUse::log_directory, true, true, true, true) ==
                SecurityDecision::accept);  // Already private: no mutation.
  static_assert(DecideSecurity(SecurityUse::log_file, true, true, true, false) ==
                SecurityDecision::reject);  // Never repair a file's ACL.
  static_assert(DecideSecurity(SecurityUse::log_file, true, true, true, true) ==
                SecurityDecision::accept);
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
