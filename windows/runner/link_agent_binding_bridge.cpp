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

bool IsHexToken(const std::string& token) {
  return token.size() == 64 && std::all_of(token.begin(), token.end(), [](unsigned char c) {
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
  });
}

bool IsSystemProcess(HANDLE process) {
  HANDLE token = nullptr;
  if (!OpenProcessToken(process, TOKEN_QUERY, &token)) return false;
  DWORD needed = 0;
  GetTokenInformation(token, TokenUser, nullptr, 0, &needed);
  std::vector<BYTE> buffer(needed);
  BYTE system_sid[SECURITY_MAX_SID_SIZE];
  DWORD sid_size = sizeof(system_sid);
  const bool ok = needed > 0 &&
      GetTokenInformation(token, TokenUser, buffer.data(), needed, &needed) &&
      CreateWellKnownSid(WinLocalSystemSid, nullptr, system_sid, &sid_size) &&
      EqualSid(reinterpret_cast<TOKEN_USER*>(buffer.data())->User.Sid, system_sid);
  CloseHandle(token);
  return ok;
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
    throw std::runtime_error("Windows Link service is not ready");
  }
  HANDLE pipe = CreateFileW(pipe_name, GENERIC_READ | GENERIC_WRITE, 0, nullptr,
                            OPEN_EXISTING,
                            SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION, nullptr);
  if (pipe == INVALID_HANDLE_VALUE) {
    SecureZeroMemory(token.data(), token.size());
    SecureZeroMemory(server_url.data(), server_url.size());
    throw std::runtime_error("Could not connect to Windows Link service");
  }

  ULONG server_pid = 0;
  DWORD server_session = MAXDWORD;
  HANDLE server = nullptr;
  if (GetNamedPipeServerProcessId(pipe, &server_pid))
    server = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, server_pid);
  const bool trusted = server && IsSystemProcess(server) &&
      ProcessIdToSessionId(server_pid, &server_session) && server_session == 0;
  if (server) CloseHandle(server);
  if (!trusted) {
    CloseHandle(pipe);
    SecureZeroMemory(token.data(), token.size());
    SecureZeroMemory(server_url.data(), server_url.size());
    throw std::runtime_error("Connected pipe is not owned by the Windows Link service");
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
    throw std::runtime_error("Could not send Link binding request");
  }

  char response[512]{};
  DWORD read = 0;
  const bool read_ok = ReadFile(pipe, response, sizeof(response) - 1, &read, nullptr) && read > 0;
  CloseHandle(pipe);
  if (!read_ok) throw std::runtime_error("Windows Link service did not return a binding result");
  const std::string body(response, read);
  SecureZeroMemory(response, sizeof(response));
  constexpr char ok_prefix[] = "{\"ok\":true,\"fingerprint\":\"";
  constexpr char ok_suffix[] = "\"}";
  if (body.size() != sizeof(ok_prefix) - 1 + 64 + sizeof(ok_suffix) - 1 ||
      body.compare(0, sizeof(ok_prefix) - 1, ok_prefix) != 0 ||
      body.compare(body.size() - (sizeof(ok_suffix) - 1), sizeof(ok_suffix) - 1, ok_suffix) != 0) {
    throw std::runtime_error("Windows Link service rejected host binding");
  }
  const std::string fingerprint = body.substr(sizeof(ok_prefix) - 1, 64);
  if (!IsHexToken(fingerprint)) throw std::runtime_error("Windows Link service returned an invalid fingerprint");
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
      } catch (const std::exception&) {
        busy->store(false);
        result->Error("binding_failed", "Windows Link host binding failed");
      }
    }).detach();
  });
}

LinkAgentBindingBridge::~LinkAgentBindingBridge() {
  channel_->SetMethodCallHandler(nullptr);
}
