// rdp_gate.cpp — клиент CP-гейта RDP MFA: WinHTTP GET + BCrypt (CNG) SHA256.
//
// Контракт сервера (2fa internal/api/rdp_cp.go):
//   GET /api/v1/cp/rdp-mfa-satisfied?username=X&machine=Y
//   X-CP-Secret: hex(SHA256("ligament-cp:" + server.domain))   → {"satisfied": bool}
// server.domain на сервере = настроенный домен БЕЗ хвостового '/'
// (strings.TrimRight при загрузке настроек) — CP вычисляет тот же секрет
// из ServerURL реестра с идентичной нормализацией.
#include "rdp_gate.h"

#include <bcrypt.h>

#pragma comment(lib, "bcrypt.lib")

namespace ligament {

// Нормализация домена ровно как на сервере: TrimSpace + TrimRight "/"
// (settings.go: t.Server.Domain = strings.TrimRight(parseString(...), "/")).
// Реестр-значение может нести хвостовые слэши/пробелы — секрет обязан
// совпасть с вычисленным ядром от «чистого» домена.
static std::wstring NormalizeDomain(const std::wstring& url) {
    size_t first = url.find_first_not_of(L" \t\r\n");
    if (first == std::wstring::npos) return std::wstring();
    size_t last = url.find_last_not_of(L" \t\r\n");
    std::wstring d = url.substr(first, last - first + 1);
    while (!d.empty() && d.back() == L'/') {
        d.pop_back();
    }
    return d;
}

// Percent-encoding UTF-8 строки для query-string (RFC 3986, unreserved
// набор). Имя пользователя может содержать кириллицу/спецсимволы —
// Go-сторона r.URL.Query() раскодирует percent+UTF-8 обратно.
static std::string UrlEncodeUtf8(const std::string& s) {
    static const char hex[] = "0123456789ABCDEF";
    std::string out;
    out.reserve(s.size() + 8);
    for (unsigned char c : s) {
        if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
            (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.' || c == '~') {
            out += (char)c;
        } else {
            out += '%';
            out += hex[c >> 4];
            out += hex[c & 0x0F];
        }
    }
    return out;
}

// hex(SHA256("ligament-cp:" + domain)) — CNG (BCrypt), НЕ WinCrypt
// (deprecated). Повторяет cpSecret() ядра: тот же префикс, тот же вход,
// hex в нижнем регистре (Go hex.EncodeToString).
static std::string CpSecretHex(const std::string& domainUtf8) {
    std::string out;
    BCRYPT_ALG_HANDLE hAlg = nullptr;
    BCRYPT_HASH_HANDLE hHash = nullptr;

    NTSTATUS st = BCryptOpenAlgorithmProvider(&hAlg, BCRYPT_SHA256_ALGORITHM, nullptr, 0);
    if (st != 0) return out;

    do {
        st = BCryptCreateHash(hAlg, &hHash, nullptr, 0, nullptr, 0, 0);
        if (st != 0) break;

        std::string input = "ligament-cp:" + domainUtf8;
        st = BCryptHashData(hHash, (PUCHAR)input.data(), (ULONG)input.size(), 0);
        if (st != 0) break;

        BYTE hash[32] = {0}; // SHA-256 = 32 байта
        st = BCryptFinishHash(hHash, hash, sizeof(hash), 0);
        if (st != 0) break;

        static const char hex[] = "0123456789abcdef";
        out.reserve(sizeof(hash) * 2);
        for (BYTE b : hash) {
            out += hex[b >> 4];
            out += hex[b & 0x0F];
        }
    } while (false);

    if (hHash) BCryptDestroyHash(hHash);
    BCryptCloseAlgorithmProvider(hAlg, 0);
    return out;
}

RdpGateResult CheckRdpMfaSatisfied(
    const std::wstring& serverUrl,
    const std::wstring& username,
    const std::wstring& computerName,
    bool allowSelfSigned,
    bool allowHttp)
{
    RdpGateResult res;

    const std::wstring domain = NormalizeDomain(serverUrl);
    if (domain.empty() || username.empty() || computerName.empty()) {
        res.note = "not_configured";
        return res;
    }

    // Схема — та же политика, что у HttpApiClient::ParseUrl (VULN-27):
    // только https; http — исключительно при явном AllowHttp (тестовые
    // стенды). Гейт не несёт кредов, но политику канала не ослабляем.
    URL_COMPONENTS uc = {0};
    uc.dwStructSize = sizeof(uc);
    wchar_t host[512] = {0};
    uc.lpszHostName = host;
    uc.dwHostNameLength = _countof(host);
    if (!WinHttpCrackUrl(domain.c_str(), (DWORD)domain.length(), 0, &uc)) {
        res.note = "bad_url";
        return res;
    }
    const bool isHttps = (uc.nScheme == INTERNET_SCHEME_HTTPS);
    if (!isHttps && !(uc.nScheme == INTERNET_SCHEME_HTTP && allowHttp)) {
        res.note = "scheme_rejected";
        return res;
    }

    // Секрет: hex(SHA256("ligament-cp:" + нормализованный домен)).
    const std::string secret = CpSecretHex(WideToUtf8(domain));
    if (secret.empty()) {
        res.note = "sha256_failed";
        return res;
    }

    // Путь после encoding — чистый ASCII, конвертация в wide безопасна.
    const std::string path8 = "/api/v1/cp/rdp-mfa-satisfied?username="
        + UrlEncodeUtf8(WideToUtf8(username))
        + "&machine=" + UrlEncodeUtf8(WideToUtf8(computerName));
    const std::wstring path = Utf8ToWide(path8);

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
    // права держать вход. resolve/connect/send 2 c, receive 3 c: типовой
    // отказ сети закрывается за connect-таймаут.
    WinHttpSetTimeouts(hSession, 2000, 2000, 2000, 3000);

    HINTERNET hConnect = WinHttpConnect(hSession, host, uc.nPort, 0);
    if (!hConnect) {
        res.note = "network_error";
        WinHttpCloseHandle(hSession);
        return res;
    }

    HINTERNET hRequest = WinHttpOpenRequest(
        hConnect,
        L"GET",
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

    const std::wstring headers = L"X-CP-Secret: " + Utf8ToWide(secret) + L"\r\n";
    BOOL ok = WinHttpSendRequest(
        hRequest,
        headers.c_str(),
        (DWORD)-1,   // -1 = WinHttp сам считает длину по нуль-терминатору
        nullptr, 0, 0, 0);
    if (ok) {
        ok = WinHttpReceiveResponse(hRequest, nullptr);
    }

    if (!ok) {
        // Транспортный отказ (недоступен/DNS/TLS/таймаут) — fail-closed:
        // обычный MFA-каскад, CP-флоу не меняется.
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

    std::string body;
    DWORD dwDownloaded = 0;
    do {
        dwSize = 0;
        if (!WinHttpQueryDataAvailable(hRequest, &dwSize)) break;
        if (dwSize == 0) break;
        std::vector<char> buffer(dwSize + 1, 0);
        if (WinHttpReadData(hRequest, buffer.data(), dwSize, &dwDownloaded)) {
            body.append(buffer.data(), dwDownloaded);
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
    res.satisfied = ExtractJsonBool(body, "satisfied");
    res.note = res.satisfied ? "satisfied" : "not_satisfied";
    return res;
}

} // namespace ligament
