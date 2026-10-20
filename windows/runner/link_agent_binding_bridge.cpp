#include "link_agent_binding_bridge.h"

#include <windows.h>

#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <atomic>
#include <memory>
#include <string>
#include <stdexcept>
#include <thread>
#include <utility>
#include <vector>

namespace {
using flutter::EncodableMap;
using flutter::EncodableValue;

class BindingException : public std::runtime_error {
 public:
  BindingException(const char* code, const std::string& message)
      : std::runtime_error(message), code_(code) {}
  const char* code() const { return code_; }

 private:
  const char* code_;
};

bool IsHexToken(const std::string& token) {
  return token.size() == 64 && std::all_of(token.begin(), token.end(), [](unsigned char c) {
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
  });
}

std::string Win32Diagnostic(const char* operation, DWORD error) {
  return std::string(operation) + " (Win32 error " + std::to_string(error) + ")";
}

std::string JsonString(const std::string& value) {
  std::string encoded = "\"";
  for (unsigned char c : value) {
    switch (c) {
      case '"': encoded += "\\\""; break;
      case '\\': encoded += "\\\\"; break;
      case '\b': encoded += "\\b"; break;
      case '\f': encoded += "\\f"; break;
      case '\n': encoded += "\\n"; break;
      case '\r': encoded += "\\r"; break;
      case '\t': encoded += "\\t"; break;
      default:
        if (c < 0x20) {
          constexpr char hex[] = "0123456789abcdef";
          encoded += "\\u00";
          encoded += hex[(c >> 4) & 0x0f];
          encoded += hex[c & 0x0f];
        } else {
          encoded += static_cast<char>(c);
        }
    }
  }
  encoded += '"';
  return encoded;
}

std::string BindOverNamedPipe(std::string server_url, std::string token) {
  constexpr wchar_t pipe_name[] = L"\\\\.\\pipe\\ligament-agent-bind";
  if (!WaitNamedPipeW(pipe_name, 5000)) {
    SecureZeroMemory(token.data(), token.size());
    SecureZeroMemory(server_url.data(), server_url.size());
    throw BindingException("link_agent_service_not_running",
                           "Ligament Link Agent service is not running");
  }
  HANDLE pipe = CreateFileW(pipe_name, GENERIC_READ | GENERIC_WRITE, 0, nullptr,
                            OPEN_EXISTING,
                            SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION, nullptr);
  if (pipe == INVALID_HANDLE_VALUE) {
    SecureZeroMemory(token.data(), token.size());
    SecureZeroMemory(server_url.data(), server_url.size());
    throw BindingException("link_agent_pipe_unavailable",
                           "Cannot connect to Ligament Link Agent service pipe");
  }

  ULONG server_pid = 0;
  DWORD server_session = MAXDWORD;
  bool trusted = false;
  const char* trust_error_code = "link_agent_service_untrusted";
  std::string trust_error = "Link service identity check failed";
  if (!GetNamedPipeServerProcessId(pipe, &server_pid)) {
    trust_error_code = "link_agent_pipe_server_pid_failed";
    trust_error = Win32Diagnostic("Cannot identify named-pipe server", GetLastError());
  } else {
    // A standard user cannot reliably OpenProcess on a LocalSystem service.
    // Query SCM instead, then bind the pipe server PID to that exact service.
    SC_HANDLE manager = OpenSCManagerW(nullptr, nullptr, SC_MANAGER_CONNECT);
    if (!manager) {
      trust_error = Win32Diagnostic("Cannot inspect Link service manager", GetLastError());
    } else {
      SC_HANDLE service = OpenServiceW(manager, L"LigamentLinkAgent",
                                       SERVICE_QUERY_STATUS | SERVICE_QUERY_CONFIG);
      if (!service) {
        trust_error = Win32Diagnostic("Cannot inspect Link service", GetLastError());
      } else {
        SERVICE_STATUS_PROCESS status{};
        DWORD needed = 0;
        if (!QueryServiceStatusEx(service, SC_STATUS_PROCESS_INFO,
                                  reinterpret_cast<LPBYTE>(&status), sizeof(status), &needed)) {
          trust_error = Win32Diagnostic("Cannot inspect Link service status", GetLastError());
        } else if (status.dwCurrentState != SERVICE_RUNNING || status.dwProcessId != server_pid) {
          trust_error = "Named-pipe server is not the running Link service";
        } else {
          QueryServiceConfigW(service, nullptr, 0, &needed);
          if (GetLastError() != ERROR_INSUFFICIENT_BUFFER || needed == 0 || needed > 65536) {
            trust_error = "Cannot size Link service configuration";
          } else {
            std::vector<BYTE> config_buffer(needed);
            auto* config = reinterpret_cast<QUERY_SERVICE_CONFIGW*>(config_buffer.data());
            if (!QueryServiceConfigW(service, config, needed, &needed)) {
              trust_error = Win32Diagnostic("Cannot inspect Link service account", GetLastError());
            } else if (!config->lpServiceStartName ||
                       lstrcmpiW(config->lpServiceStartName, L"LocalSystem") != 0) {
              trust_error_code = "link_agent_service_sid_mismatch";
              trust_error = "Link service is not configured as LocalSystem";
            } else if (!ProcessIdToSessionId(server_pid, &server_session)) {
              trust_error_code = "link_agent_service_session_check_failed";
              trust_error = Win32Diagnostic("Cannot verify Link service session", GetLastError());
            } else if (server_session != 0) {
              trust_error_code = "link_agent_service_not_session0";
              trust_error = "Link service process is not running in Session 0";
            } else {
              trusted = true;
            }
          }
        }
        CloseServiceHandle(service);
      }
      CloseServiceHandle(manager);
    }
  }
  if (!trusted) {
    CloseHandle(pipe);
    SecureZeroMemory(token.data(), token.size());
    SecureZeroMemory(server_url.data(), server_url.size());
    throw BindingException(trust_error_code, trust_error);
  }

  std::string request = "{\"version\":1,\"server_url\":" + JsonString(server_url) +
      ",\"enrollment_token\":\"" + token + "\"}";
  SecureZeroMemory(token.data(), token.size());
  SecureZeroMemory(server_url.data(), server_url.size());
  DWORD written = 0;
  const bool write_ok = WriteFile(pipe, request.data(), static_cast<DWORD>(request.size()), &written, nullptr) &&
      written == request.size();
  SecureZeroMemory(request.data(), request.size());
  if (!write_ok) {
    CloseHandle(pipe);
    throw BindingException("link_agent_pipe_communication_failed",
                           "Could not send the binding request to Link service");
  }

  char response[512]{};
  DWORD read = 0;
  const bool read_ok = ReadFile(pipe, response, sizeof(response) - 1, &read, nullptr) && read > 0;
  CloseHandle(pipe);
  if (!read_ok) {
    throw BindingException("link_agent_pipe_communication_failed",
                           "Link service did not return a binding result");
  }
  const std::string body(response, read);
  SecureZeroMemory(response, sizeof(response));
  constexpr char ok_prefix[] = "{\"ok\":true,\"fingerprint\":\"";
  constexpr char ok_suffix[] = "\"}";
  if (body.size() != sizeof(ok_prefix) - 1 + 64 + sizeof(ok_suffix) - 1 ||
      body.compare(0, sizeof(ok_prefix) - 1, ok_prefix) != 0 ||
      body.compare(body.size() - (sizeof(ok_suffix) - 1), sizeof(ok_suffix) - 1, ok_suffix) != 0) {
    constexpr char error_prefix[] = "{\"ok\":false,\"error\":\"";
    constexpr char error_suffix[] = "\"}";
    const size_t prefix_size = sizeof(error_prefix) - 1;
    const size_t suffix_size = sizeof(error_suffix) - 1;
    if (body.size() > prefix_size + suffix_size &&
        body.compare(0, prefix_size, error_prefix) == 0 &&
        body.compare(body.size() - suffix_size, suffix_size, error_suffix) == 0) {
      const std::string code = body.substr(prefix_size, body.size() - prefix_size - suffix_size);
      if (code == "server_mismatch")
        throw BindingException("link_agent_server_mismatch",
                               "App and Windows service use different server URLs");
      if (code == "host_already_enrolled")
        throw BindingException("link_agent_host_already_enrolled",
                               "This computer is already enrolled");
      if (code == "identity_store_failed")
        throw BindingException("link_agent_identity_store_failed",
                               "Windows service could not save the host identity");
      if (code == "enrollment_rejected")
        throw BindingException("link_agent_enrollment_rejected",
                               "Server rejected host enrollment; check the Link agent log");
    }
    throw BindingException("link_agent_enrollment_rejected",
                           "Windows Link service rejected host enrollment");
  }
  const std::string fingerprint = body.substr(sizeof(ok_prefix) - 1, 64);
  if (!IsHexToken(fingerprint))
    throw BindingException("link_agent_invalid_response",
                           "Windows Link service returned an invalid fingerprint");
  return fingerprint;
}
}  // namespace

LinkAgentBindingBridge::LinkAgentBindingBridge(flutter::BinaryMessenger* messenger)
    : busy_(std::make_shared<std::atomic_bool>(false)),
      channel_(std::make_unique<flutter::MethodChannel<EncodableValue>>(
          messenger, "ligament/link_agent", &flutter::StandardMethodCodec::GetInstance())) {
  channel_->SetMethodCallHandler([busy = busy_](const auto& call, auto result) mutable {
    if (call.method_name() != "bindHost") {
      result->NotImplemented();
      return;
    }
    const auto* args = call.arguments() ? std::get_if<EncodableMap>(call.arguments()) : nullptr;
    const auto token_it = args ? args->find(EncodableValue("enrollment_token")) : EncodableMap::const_iterator{};
    const auto url_it = args ? args->find(EncodableValue("server_url")) : EncodableMap::const_iterator{};
    const auto* token = args && token_it != args->end()
        ? std::get_if<std::string>(&token_it->second) : nullptr;
    const auto* server_url = args && url_it != args->end()
        ? std::get_if<std::string>(&url_it->second) : nullptr;
    if (!token || !IsHexToken(*token) || !server_url || server_url->empty() || server_url->size() > 2048) {
      result->Error("invalid_binding_request", "Invalid Link host binding request");
      return;
    }
    bool expected = false;
    if (!busy->compare_exchange_strong(expected, true)) {
      result->Error("binding_in_progress", "A Link host binding is already in progress");
      return;
    }
    std::string server_url_copy = *server_url;
    std::string token_copy = *token;
    std::thread([busy, server_url = std::move(server_url_copy), token = std::move(token_copy), result = std::move(result)]() mutable {
      try {
        const auto fingerprint = BindOverNamedPipe(std::move(server_url), std::move(token));
        busy->store(false);
        result->Success(EncodableValue(fingerprint));
      } catch (const BindingException& error) {
        busy->store(false);
        result->Error(error.code(), error.what());
      } catch (const std::exception&) {
        busy->store(false);
        result->Error("link_agent_binding_failed", "Windows Link host binding failed");
      }
    }).detach();
  });
}

LinkAgentBindingBridge::~LinkAgentBindingBridge() {
  channel_->SetMethodCallHandler(nullptr);
}
