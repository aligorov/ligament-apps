// rdp_gate.cpp — клиент CP-гейта RDP MFA: logon-bound assertion
// (WinHTTP POST + named pipe + реестр; LogonId через GetTokenInformation).
//
// Контракт сервера (2fa internal/api/rdp_cp.go, миграция 0065):
//   POST /api/v1/cp/rdp-assert  {"nonce":hex,"logon_id":hex,"machine":...}
//   Authorization: Bearer <agent_key endpoint'а>            → {"satisfied": bool}
// Аутентификация запроса — агентским ключом endpoint'а (sha256 в БД):
// вычислить его из домена/имени машины нельзя, в отличие от прежнего
// X-CP-Secret (аудит P1 #2).
#include "rdp_gate.h"

namespace ligament {

#ifndef GetCurrentThreadEffectiveToken
#define GetCurrentThreadEffectiveToken() ((HANDLE)(LONG_PTR)-6)
#endif

// ---- agent_key endpoint'службы из реестра (приоритет Policies → локальный,
// как endpoint_service.cpp / GPO-настройки CP) ----
static std::wstring ReadAgentKeyFromRegistry() {
    const wchar_t* keys[2] = {
        L"SOFTWARE\\Policies\\Ligament\\2FA",
        L"SOFTWARE\\Ligament\\2FA",
    };
    for (auto keyPath : keys) {
        HKEY hKey = nullptr;
        if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, keyPath, 0, KEY_READ | KEY_WOW64_64KEY, &hKey) == ERROR_SUCCESS) {
            wchar_t buf[256] = {0};
            DWORD type = 0, size = sizeof(buf) - sizeof(wchar_t);
            if (RegQueryValueExW(hKey, L"RdpAgentKey", nullptr, &type, (LPBYTE)buf, &size) == ERROR_SUCCESS &&
                type == REG_SZ) {
                RegCloseKey(hKey);
                return buf;
            }
            RegCloseKey(hKey);
        }
    }
    return std::wstring();
}

// ---- LogonId: LUID логон-сессии контекста CP (LogonUI/winlogon) ----
// У каждого входящего RDP-подключения своё логон-окно со своим LUID:
// AuthenticationId токена CP уникален для этого окна входа и не совпадает
// с окном другого подключения (сервер фиксирует его в rdp_assertions для
// аудита; пустой logon_id ядро отвергает).
static std::string CurrentLogonIdHex() {
    HANDLE tok = GetCurrentThreadEffectiveToken();
    DWORD need = 0;
    GetTokenInformation(tok, TokenStatistics, nullptr, 0, &need);
    if (need == 0 || need > 4096) return "";
    std::vector<BYTE> buf(need, 0);
    if (!GetTokenInformation(tok, TokenStatistics, buf.data(), need, &need)) return "";
    const auto* ts = reinterpret_cast<const TOKEN_STATISTICS*>(buf.data());
    char hex[17] = {0};
    sprintf_s(hex, _countof(hex), "%08x%08x",
        (unsigned)ts->AuthenticationId.HighPart,
        (unsigned)ts->AuthenticationId.LowPart);
    return hex;
}

// ---- nonce одноразового assertion у endpoint-службы (named pipe) ----
// Служба (endpoint_service.cpp) получила кадр agent_assertion от ядра и
// раздаёт nonce локальным клиентам. Протокол: подключиться и прочитать
// один JSON {"nonce":"<hex>|"}; запрос не нужен. Чтение ограничено
// поллингом PeekNamedPipe (~2 с) — блокировки потока без таймаута нет.
static std::string QueryAssertionNonce() {
    const wchar_t* kPipe = L"\\\\.\\pipe\\LigamentRdpGate";
    if (!WaitNamedPipeW(kPipe, 2000)) return ""; // служба не подняла pipe
    HANDLE h = CreateFileW(kPipe, GENERIC_READ, 0, nullptr, OPEN_EXISTING, 0, nullptr);
    if (h == INVALID_HANDLE_VALUE) return "";
    std::string out;
    out.reserve(128);
    for (int poll = 0; poll < 100 && out.size() < 512; ++poll) {
        DWORD avail = 0;
        if (!PeekNamedPipe(h, nullptr, 0, nullptr, &avail, nullptr)) break; // сервер оборвал
        if (avail == 0) {
            if (poll == 99) break;
            Sleep(20);
            continue;
        }
        char buf[256];
        DWORD want = avail < sizeof(buf) ? avail : (DWORD)sizeof(buf);
        DWORD readN = 0;
        if (!ReadFile(h, buf, want, &readN, nullptr) || readN == 0) break;
        out.append(buf, readN);
        if (out.find('}') != std::string::npos) break; // JSON закрыт
    }
    CloseHandle(h);
    return ExtractJsonString(out, "nonce");
}

RdpGateResult CheckRdpMfaSatisfied(
    const std::wstring& serverUrl,
    const std::wstring& computerName,
    bool allowSelfSigned,
    bool allowHttp)
{
    RdpGateResult res;

    if (serverUrl.empty() || computerName.empty()) {
        res.note = "not_configured";
        return res;
    }
    const std::wstring agentKey = ReadAgentKeyFromRegistry();
    if (agentKey.empty()) {
        res.note = "no_agent_key"; // машина не endpoint RDP-шлюза
        return res;
    }
    const std::string nonce = QueryAssertionNonce();
    if (nonce.empty()) {
        res.note = "no_assertion"; // нет живого окна (службы/claim/nonce)
        return res;
    }
    const std::string logonId = CurrentLogonIdHex();
    if (logonId.empty()) {
        res.note = "logon_id_failed";
        return res;
    }

    // Схема — та же политика, что у HttpApiClient::ParseUrl (VULN-27):
    // только https; http — исключительно при явном AllowHttp (тестовые
    // стенды). Гейт не несёт пароля, но несёт agent_key — не ослабляем.
    URL_COMPONENTS uc = {0};
    uc.dwStructSize = sizeof(uc);
    wchar_t host[512] = {0};
    uc.lpszHostName = host;
    uc.dwHostNameLength = _countof(host);
    if (!WinHttpCrackUrl(serverUrl.c_str(), (DWORD)serverUrl.length(), 0, &uc)) {
        res.note = "bad_url";
        return res;
    }
    const bool isHttps = (uc.nScheme == INTERNET_SCHEME_HTTPS);
    if (!isHttps && !(uc.nScheme == INTERNET_SCHEME_HTTP && allowHttp)) {
        res.note = "scheme_rejected";
        return res;
    }

    // Тело/путь — чистый ASCII (machine через UTF-8+escape), wide безопасен.
    const std::string body = std::string("{\"nonce\":\"") + EscapeJson(nonce) +
        "\",\"logon_id\":\"" + logonId +
        "\",\"machine\":\"" + EscapeJson(WideToUtf8(computerName)) + "\"}";
    const std::wstring path = L"/api/v1/cp/rdp-assert";

    HINTERNET hSession = WinHttpOpen(
        L"Ligament-2FA-CredentialProvider/1.0",
        WINHTTP_ACCESS_TYPE_DEFAULT_PROXY,
        WINHTTP_NO_PROXY_NAME,
        WINHTTP_NO_PROXY_BYPASS,
        0);
    if (!hSession) {
        res.note = "winhttp_open_failed";
        return res;
    }
    // Короткие таймауты (~3 c): гейт — пре-фаза MFA-каскада и не имеет
    // права держать вход. resolve/connect/send 2 c, receive 3 c.
    WinHttpSetTimeouts(hSession, 2000, 2000, 2000, 3000);

    HINTERNET hConnect = WinHttpConnect(hSession, host, uc.nPort, 0);
    if (!hConnect) {
        res.note = "network_error";
        WinHttpCloseHandle(hSession);
        return res;
    }

    HINTERNET hRequest = WinHttpOpenRequest(
        hConnect,
        L"POST",
        path.c_str(),
        nullptr,
        WINHTTP_NO_REFERER,
        WINHTTP_DEFAULT_ACCEPT_TYPES,
        isHttps ? WINHTTP_FLAG_SECURE : 0);
    if (!hRequest) {
        res.note = "network_error";
        WinHttpCloseHandle(hConnect);
        WinHttpCloseHandle(hSession);
        return res;
    }

    // AllowSelfSigned ослабляет ТОЛЬКО проверку цепочки до корня — имя
    // хоста/срок/назначение сертификата проверяются всегда (как в
    // HttpApiClient::SendRequest).
    if (isHttps && allowSelfSigned) {
        DWORD dwSecFlags = SECURITY_FLAG_IGNORE_UNKNOWN_CA;
        WinHttpSetOption(hRequest, WINHTTP_OPTION_SECURITY_FLAGS, &dwSecFlags, sizeof(dwSecFlags));
    }

    const std::wstring headers =
        L"Authorization: Bearer " + agentKey + L"\r\n" \
        L"Content-Type: application/json\r\n";
    BOOL ok = WinHttpSendRequest(
        hRequest,
        headers.c_str(),
        (DWORD)-1,   // -1 = WinHttp сам считает длину по нуль-терминатору
        (LPVOID)body.data(),
        (DWORD)body.size(),
        (DWORD)body.size(),
        0);
    if (ok) {
        ok = WinHttpReceiveResponse(hRequest, nullptr);
    }

    if (!ok) {
        // Транспортный отказ (недоступен/DNS/TLS/таймаут) — fail-closed:
        // обычный MFA-каскад, CP-флоу не меняется. Assertion на сервере
        // НЕ погашен (ответа не было) — окно не сгорело впустую.
        res.note = "network_error";
        WinHttpCloseHandle(hRequest);
        WinHttpCloseHandle(hConnect);
        WinHttpCloseHandle(hSession);
        return res;
    }

    DWORD statusCode = 0;
    DWORD dwSize = sizeof(statusCode);
    WinHttpQueryHeaders(
        hRequest,
        WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
        WINHTTP_HEADER_NAME_BY_INDEX,
        &statusCode,
        &dwSize,
        WINHTTP_NO_HEADER_INDEX);

    std::string respBody;
    DWORD dwDownloaded = 0;
    do {
        dwSize = 0;
        if (!WinHttpQueryDataAvailable(hRequest, &dwSize)) break;
        if (dwSize == 0) break;
        std::vector<char> buffer(dwSize + 1, 0);
        if (WinHttpReadData(hRequest, buffer.data(), dwSize, &dwDownloaded)) {
            respBody.append(buffer.data(), dwDownloaded);
        }
    } while (dwSize > 0);

    WinHttpCloseHandle(hRequest);
    WinHttpCloseHandle(hConnect);
    WinHttpCloseHandle(hSession);

    // Сервер отвечает 200 и на «нет» (единый false без раскрытия причин);
    // не-200 трактуем как «гейт не ответил» → fail-closed.
    if (statusCode != 200) {
        res.note = "status_" + std::to_string((int)statusCode);
        return res;
    }

    res.responded = true;
    res.satisfied = ExtractJsonBool(respBody, "satisfied");
    res.note = res.satisfied ? "satisfied" : "not_satisfied";
    return res;
}

} // namespace ligament
