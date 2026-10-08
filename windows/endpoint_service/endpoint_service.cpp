// endpoint_service.cpp — Ligament Endpoint Service («LigamentEndpointService»)
//
// Self-служба RDP Access Gateway (этап 2.3 плана docs/rdp-client-stage2-plan.md
// §4; сервер — 2fa internal/api/rdp_agent_hub.go): живёт на ЦЕЛЕВОМ ПК,
// сама инициирует исходящий WSS к ядру, регистрируется по agent_key и по
// команде ядра (agent_dial) открывает TCP к 127.0.0.1:3389 и перекачивает
// байты. Входящих портов нет вообще.
//
// Протокол (контроль — текстовые JSON-кадры, данные — БИНАРНЫЕ кадры
// [8B stream_id BE uint64][TCP data]):
//   ядро → агент: {"type":"agent_hello","endpoint_id":...}        (после upgrade)
//   ядро → агент: {"type":"agent_dial","stream_id":N,"host":H,"port":P}
//   агент → ядро: {"type":"agent_opened","stream_id":N}
//                 {"type":"agent_error","stream_id":N,"error":"..."}
//   обе стороны:  бинарный кадр = сырые байты ↔ TCP 127.0.0.1:3389
//   обе стороны:  {"type":"agent_close","stream_id":N,"reason":"..."}
//   агент → ядро: {"type":"ping"} → {"type":"pong"} (поверх WS ping/pong)
//   ядро → агент: {"type":"agent_assertion","nonce":"<hex>","expires_in":N,
//                  "grant_id":...} — одноразовый assertion CP-гейта после
//                  claim гранта (аудит P1 #2 2026-10-08): служба хранит
//                  nonce в памяти и отдаёт его локальному Ligament-CP
//                  через named pipe \\.\pipe\LigamentRdpGate (см. ниже).
//
// LOOPBACK ENFORCEMENT (план §4: «endpoint открывает ТОЛЬКО локальный RDP
// и не является универсальным прокси»): host/port из agent_dial ИГНОРИРУЮТСЯ,
// набор всегда 127.0.0.1:<RdpAgentTargetPort=3389> — allowlist зашит.
//
// Конфигурация (реестр, приоритет Policies → локальный ключ, как CP и
// GpoService): ServerURL (REG_SZ, пишется MSI AppServerUrlRegistry),
// RdpAgentKey (REG_SZ «<uuid>:<hex>»), RdpAgentEnabled (DWORD, 0=пассивна),
// RdpAgentTargetPort (DWORD, default 3389), AllowSelfSigned / AllowHttp
// (DWORD, только для изолированных тестовых стендов).
//
// Реконнект: экспоненциальный backoff 1с→2с→…→капа 60с, джиттер ±20%,
// сброс после 60с стабильного соединения — порт 1:1 ReconnectBackoff из
// lib/services/ws_service.dart (юнит-тесты логики там же).
//
// Лог: C:\ProgramData\Ligament\endpoint.log (DACL SYSTEM/Admins — как
// service.log / cp.log).
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winhttp.h>
#include <winsock2.h>
#include <ws2tcpip.h>
#include <shlobj.h>
#include <sddl.h>
#include <stdio.h>
#include <cctype>
#include <cwctype>
#include <atomic>
#include <chrono>
#include <map>
#include <memory>
#include <mutex>
#include <random>
#include <string>
#include <thread>
#include <vector>

#pragma comment(lib, "winhttp.lib")
#pragma comment(lib, "ws2_32.lib")
#pragma comment(lib, "advapi32.lib")

namespace {

const wchar_t* kSvcName = L"LigamentEndpointService";
const char kAgentVersion[] = "1.0.0";
const int kStableResetMs = 60000;   // сброс backoff после минуты стабильности
const int kPingEveryMs = 25000;     // app-level ping (сердцебиение ниже WS-пингов WinHTTP)
const int kDialTimeoutSec = 4;      // connect до 127.0.0.1:3389

SERVICE_STATUS g_status = {};
SERVICE_STATUS_HANDLE g_hStatus = nullptr;
HANDLE g_hStop = nullptr;

// ---------------- Лог: ProgramData\Ligament\endpoint.log ----------------

void LogLine(const wchar_t* line) {
    static wchar_t s_path[MAX_PATH] = {0};
    static bool s_disabled = false;
    if (s_disabled) return;
    if (s_path[0] == 0) {
        wchar_t progData[MAX_PATH] = {0};
        if (FAILED(SHGetFolderPathW(nullptr, CSIDL_COMMON_APPDATA, nullptr, 0, progData))) {
            s_disabled = true;
            return;
        }
        wcscat_s(progData, L"\\Ligament");
        SECURITY_ATTRIBUTES sa = {sizeof(SECURITY_ATTRIBUTES), nullptr, FALSE};
        if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
                L"D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)", SDDL_REVISION_1,
                &sa.lpSecurityDescriptor, nullptr)) {
            sa.lpSecurityDescriptor = nullptr;
        }
        CreateDirectoryW(progData, sa.lpSecurityDescriptor ? &sa : nullptr);
        wcscat_s(progData, L"\\endpoint.log");
        wcscpy_s(s_path, progData);
    }
    HANDLE h = CreateFileW(s_path, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE,
        nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
    if (h == INVALID_HANDLE_VALUE) return;
    SetFilePointer(h, 0, nullptr, FILE_END);
    DWORD written = 0;
    WriteFile(h, line, (DWORD)(wcslen(line) * sizeof(wchar_t)), &written, nullptr);
    CloseHandle(h);
}

void Log(const wchar_t* fmt, ...) {
    wchar_t body[512];
    va_list args;
    va_start(args, fmt);
    _vsnwprintf_s(body, _countof(body), _TRUNCATE, fmt, args);
    va_end(args);

    SYSTEMTIME st;
    GetLocalTime(&st);
    wchar_t line[600];
    swprintf_s(line, L"[%02u.%02u %02u:%02u:%02u] %s\r\n",
        st.wDay, st.wMonth, st.wHour, st.wMinute, st.wSecond, body);
    LogLine(line);
}

// ---------------- Конфигурация (реестр) ----------------

struct Config {
    std::wstring serverUrl;
    std::wstring agentKey;
    bool enabled = false;
    bool allowSelfSigned = false;
    bool allowHttp = false;
    int targetPort = 3389;

    bool Valid() const { return enabled && !serverUrl.empty() && !agentKey.empty(); }
};

// Приоритет: Policies (GPO/MDM) → локальный ключ — как PolicyAllowExit в
// service.cpp и GpoService приложения.
bool ReadRegDword(const wchar_t* name, DWORD& out) {
    const wchar_t* keys[2] = {
        L"SOFTWARE\\Policies\\Ligament\\2FA",
        L"SOFTWARE\\Ligament\\2FA",
    };
    for (auto keyPath : keys) {
        HKEY hKey = nullptr;
        if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, keyPath, 0, KEY_READ | KEY_WOW64_64KEY, &hKey) == ERROR_SUCCESS) {
            DWORD val = 0, type = 0, size = sizeof(val);
            if (RegQueryValueExW(hKey, name, nullptr, &type, (LPBYTE)&val, &size) == ERROR_SUCCESS &&
                type == REG_DWORD) {
                RegCloseKey(hKey);
                out = val;
                return true;
            }
            RegCloseKey(hKey);
        }
    }
    return false;
}

bool ReadRegString(const wchar_t* name, std::wstring& out) {
    const wchar_t* keys[2] = {
        L"SOFTWARE\\Policies\\Ligament\\2FA",
        L"SOFTWARE\\Ligament\\2FA",
    };
    for (auto keyPath : keys) {
        HKEY hKey = nullptr;
        if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, keyPath, 0, KEY_READ | KEY_WOW64_64KEY, &hKey) == ERROR_SUCCESS) {
            wchar_t buf[1024] = {0};
            DWORD type = 0, size = sizeof(buf) - sizeof(wchar_t);
            if (RegQueryValueExW(hKey, name, nullptr, &type, (LPBYTE)buf, &size) == ERROR_SUCCESS &&
                type == REG_SZ) {
                RegCloseKey(hKey);
                out = buf;
                return true;
            }
            RegCloseKey(hKey);
        }
    }
    return false;
}

bool LoadConfig(Config& cfg) {
    ReadRegString(L"ServerURL", cfg.serverUrl);
    ReadRegString(L"RdpAgentKey", cfg.agentKey);
    DWORD v = 0;
    if (ReadRegDword(L"RdpAgentEnabled", v)) cfg.enabled = (v != 0);
    if (ReadRegDword(L"AllowSelfSigned", v)) cfg.allowSelfSigned = (v != 0);
    if (ReadRegDword(L"AllowHttp", v)) cfg.allowHttp = (v != 0);
    if (ReadRegDword(L"RdpAgentTargetPort", v) && v > 0 && v < 65536) cfg.targetPort = (int)v;
    // Trim
    while (!cfg.serverUrl.empty() && iswspace(cfg.serverUrl.back())) cfg.serverUrl.pop_back();
    while (!cfg.serverUrl.empty() && iswspace(cfg.serverUrl.front())) cfg.serverUrl.erase(0, 1);
    return cfg.Valid();
}

// ---------------- Assertion CP-гейта (nonce для Ligament-CP) ----------------
// Ядро после claim гранта (WS-труба юзера) присылает контрольный кадр
// agent_assertion с одноразовым nonce (сервер rdp_cp.go, миграция 0065:
// TTL 5 минут, одноразовость used_at, привязка к endpoint). Состояние —
// процесс-глобальное: переживает реконнект WSS-туннеля (служба жива,
// окно подключения никуда не девается). Протухший nonce не отдаётся.

const wchar_t* kRdpGatePipeName = L"\\\\.\\pipe\\LigamentRdpGate";

struct RdpAssertionState {
    std::mutex mu;
    std::string nonce;
    ULONGLONG expiresAtTick = 0; // GetTickCount64-дедлайн
};

RdpAssertionState g_assertion;

void StoreAssertionNonce(const std::string& nonce, unsigned long long expiresInSec) {
    std::lock_guard<std::mutex> lk(g_assertion.mu);
    g_assertion.nonce = nonce;
    g_assertion.expiresAtTick = GetTickCount64() + expiresInSec * 1000ULL;
}

// Текущий ответ CP: живой nonce или пустой (нет окна/истёк).
std::string CurrentAssertionJson() {
    std::string nonce;
    {
        std::lock_guard<std::mutex> lk(g_assertion.mu);
        if (!g_assertion.nonce.empty() && GetTickCount64() < g_assertion.expiresAtTick) {
            nonce = g_assertion.nonce;
        } else {
            g_assertion.nonce.clear(); // протухший не отдаём дважды
        }
    }
    if (nonce.empty()) return "{\"nonce\":\"\"}";
    return "{\"nonce\":\"" + nonce + "\"}";
}

// Цикл named pipe для CP (LigamentCredential, фаза 0). Протокол: CP
// подключается и ЧИТАЕТ один JSON {"nonce":"<hex>|"}; запроса нет — байты
// от клиента (если были) дропаются DisconnectNamedPipe. DACL: SYSTEM и
// Администраторы (CP живёт в LogonUI/wlogon под SYSTEM; стандартный
// пользователь процесс-хендл не получает). Overlapped-подключение ждёт
// ИЛИ клиента, ИЛИ stop-события службы — shutdown не виснет на Accept.
void RdpGatePipeLoop(HANDLE hStop) {
    SECURITY_ATTRIBUTES sa = {sizeof(SECURITY_ATTRIBUTES), nullptr, FALSE};
    if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
            L"D:P(A;OICI;GA;;;SY)(A;OICI;GA;;;BA)", SDDL_REVISION_1,
            &sa.lpSecurityDescriptor, nullptr)) {
        sa.lpSecurityDescriptor = nullptr; // дефолтный DACL объекта тоже ок
    }
    for (;;) {
        if (WaitForSingleObject(hStop, 0) != WAIT_TIMEOUT) return;
        HANDLE hPipe = CreateNamedPipeW(kRdpGatePipeName,
            PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED,
            PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT,
            PIPE_UNLIMITED_INSTANCES, 256, 256, 2000,
            sa.lpSecurityDescriptor ? &sa : nullptr);
        if (hPipe == INVALID_HANDLE_VALUE) {
            // Имя занято/временно недоступно — тихая пауза и повтор.
            if (WaitForSingleObject(hStop, 5000) != WAIT_TIMEOUT) return;
            continue;
        }
        OVERLAPPED ov = {};
        ov.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
        if (!ov.hEvent) {
            CloseHandle(hPipe);
            continue;
        }
        BOOL connected = ConnectNamedPipe(hPipe, &ov);
        DWORD cerr = connected ? NO_ERROR : GetLastError();
        bool haveClient = false;
        bool stopped = false;
        if (connected || cerr == ERROR_PIPE_CONNECTED) {
            haveClient = true;
        } else if (cerr == ERROR_IO_PENDING) {
            HANDLE waits[2] = {ov.hEvent, hStop};
            DWORD w = WaitForMultipleObjects(2, waits, FALSE, INFINITE);
            if (w == WAIT_OBJECT_0) {
                DWORD dummy = 0;
                haveClient = GetOverlappedResult(hPipe, &ov, &dummy, FALSE);
            } else {
                stopped = true;
            }
        } else {
            stopped = (WaitForSingleObject(hStop, 0) != WAIT_TIMEOUT);
        }
        if (haveClient) {
            const std::string resp = CurrentAssertionJson();
            DWORD written = 0;
            ResetEvent(ov.hEvent);
            if (WriteFile(hPipe, resp.data(), (DWORD)resp.size(), &written, &ov) ||
                GetLastError() == ERROR_IO_PENDING) {
                if (WaitForSingleObject(ov.hEvent, 3000) == WAIT_OBJECT_0) {
                    GetOverlappedResult(hPipe, &ov, &written, FALSE);
                } else {
                    CancelIo(hPipe);
                }
            }
            FlushFileBuffers(hPipe);
            DisconnectNamedPipe(hPipe);
            Log(L"CP забрал assertion-гейт (длина ответа %zu)", resp.size());
        }
        CloseHandle(ov.hEvent);
        CloseHandle(hPipe);
        if (stopped) return;
    }
}

// ---------------- Backoff (порт lib/services/ws_service.dart) ----------------

class ReconnectBackoff {
public:
    ReconnectBackoff(int baseMs, int maxMs, double jitterFraction)
        : m_baseMs(baseMs), m_maxMs(maxMs), m_jitter(jitterFraction),
          m_rng((uint32_t)GetTickCount()) {}

    int NextDelayMs() {
        const int exp = m_attempt++;
        long long delayMs = (long long)m_baseMs << exp; // base * 2^attempt
        if (delayMs > m_maxMs) delayMs = m_maxMs;
        if (m_jitter > 0) {
            std::uniform_real_distribution<double> d(-m_jitter, m_jitter);
            delayMs = (long long)(delayMs * (1.0 + d(m_rng)));
        }
        if (delayMs < 0) delayMs = 0;
        if (delayMs > m_maxMs) delayMs = m_maxMs;
        return (int)delayMs;
    }

    void Reset() { m_attempt = 0; }

private:
    int m_baseMs, m_maxMs;
    double m_jitter;
    int m_attempt = 0;
    std::mt19937 m_rng;
    std::mutex m_mu;
};

// ---------------- Мини-JSON (паттерн ExtractJsonString из CP) ----------------

std::string JsonExtractString(const std::string& json, const char* key) {
    std::string needle = "\"" + std::string(key) + "\"";
    size_t p = json.find(needle);
    if (p == std::string::npos) return "";
    p = json.find(':', p + needle.size());
    if (p == std::string::npos) return "";
    p++;
    while (p < json.size() && isspace((unsigned char)json[p])) p++;
    if (p >= json.size() || json[p] != '"') return "";
    p++;
    std::string out;
    while (p < json.size() && json[p] != '"') {
        if (json[p] == '\\' && p + 1 < json.size()) p++;
        out += json[p++];
    }
    return out;
}

bool JsonExtractU64(const std::string& json, const char* key, unsigned long long& out) {
    std::string needle = "\"" + std::string(key) + "\"";
    size_t p = json.find(needle);
    if (p == std::string::npos) return false;
    p = json.find(':', p + needle.size());
    if (p == std::string::npos) return false;
    p++;
    while (p < json.size() && isspace((unsigned char)json[p])) p++;
    if (p >= json.size() || !isdigit((unsigned char)json[p])) return false;
    out = 0;
    while (p < json.size() && isdigit((unsigned char)json[p])) {
        out = out * 10 + (unsigned long long)(json[p] - '0');
        p++;
    }
    return true;
}

std::string WideToUtf8(const std::wstring& w) {
    if (w.empty()) return {};
    int n = WideCharToMultiByte(CP_UTF8, 0, w.c_str(), (int)w.size(), nullptr, 0, nullptr, nullptr);
    std::string out(n, 0);
    WideCharToMultiByte(CP_UTF8, 0, w.c_str(), (int)w.size(), &out[0], n, nullptr, nullptr);
    return out;
}

std::wstring Utf8ToWide(const std::string& s) {
    if (s.empty()) return {};
    int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), nullptr, 0);
    std::wstring out(n, 0);
    MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), &out[0], n);
    return out;
}

// ---------------- Агентская сессия ----------------

struct StreamCtx {
    unsigned long long id = 0;
    SOCKET sock = INVALID_SOCKET;
    std::atomic<bool> closedByUs{false};
};

class AgentSession : public std::enable_shared_from_this<AgentSession> {
public:
    explicit AgentSession(const Config& cfg) : m_cfg(cfg) {}

    ~AgentSession() { Teardown(); }

    // Устанавливает WSS-туннель до ядра. false — отказ (см. m_httpStatus).
    bool Connect() {
        // Разбор ServerURL: только https (http — лишь при явном AllowHttp,
        // изолированные стенды; по этому каналу ходит agent_key).
        URL_COMPONENTS uc = {0};
        uc.dwStructSize = sizeof(uc);
        wchar_t host[512] = {0};
        uc.lpszHostName = host;
        uc.dwHostNameLength = _countof(host);
        if (!WinHttpCrackUrl(m_cfg.serverUrl.c_str(), (DWORD)m_cfg.serverUrl.size(), 0, &uc)) {
            Log(L"ServerURL не разобран (%lu)", GetLastError());
            return false;
        }
        bool isHttps = (uc.nScheme == INTERNET_SCHEME_HTTPS);
        if (!isHttps && !(uc.nScheme == INTERNET_SCHEME_HTTP && m_cfg.allowHttp)) {
            Log(L"ServerURL отклонён: требуется https (AllowHttp=%d)", m_cfg.allowHttp ? 1 : 0);
            return false;
        }

        m_hSession = WinHttpOpen(L"Ligament-Endpoint/1.0",
            WINHTTP_ACCESS_TYPE_DEFAULT_PROXY, WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
        if (!m_hSession) return false;
        WinHttpSetTimeouts(m_hSession, 5000, 10000, 15000, 0);

        m_hConnect = WinHttpConnect(m_hSession, host, uc.nPort, 0);
        if (!m_hConnect) return false;

        // В query — только version (не секрет). agent_key — заголовком
        // Authorization Bearer: контракт rdp_agent_hub.HandleConnect читает
        // ключ из заголовка (аудит P2 2026-10-08 — креды в query оседают в
        // access-логах прокси и трассировке ядра).
        std::wstring path = L"/api/v1/rdp/agent/connect?version=" +
            Utf8ToWide(kAgentVersion);
        HINTERNET hRequest = WinHttpOpenRequest(m_hConnect, L"GET", path.c_str(), nullptr,
            WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES,
            isHttps ? WINHTTP_FLAG_SECURE : 0);
        if (!hRequest) return false;

        // agent_key — uuid, экранирование заголовка не требуется.
        std::wstring authHeader = L"Authorization: Bearer " + m_cfg.agentKey;
        if (!WinHttpAddRequestHeaders(hRequest, authHeader.c_str(), (DWORD)-1,
                                      WINHTTP_ADDREQ_FLAG_ADD)) {
            Log(L"Authorization-заголовок не добавлен (%lu)", GetLastError());
            WinHttpCloseHandle(hRequest);
            return false;
        }

        // WS-keepalive: WinHTTP сам шлёт ping-кадры раз в интервал и сам
        // отвечает pong на серверные ping (ядро пингует каждые 25с).
        DWORD keepaliveMs = 20000;
        WinHttpSetOption(hRequest, WINHTTP_OPTION_WEB_SOCKET_KEEPALIVE_INTERVAL,
            &keepaliveMs, sizeof(keepaliveMs));

        // AllowSelfSigned ослабляет ТОЛЬКО проверку цепочки до корня
        // (SECURITY_FLAG_IGNORE_UNKNOWN_CA) — имя хоста/срок/назначение
        // сертификата проверяются всегда (семантика HttpApiClient CP).
        if (isHttps && m_cfg.allowSelfSigned) {
            DWORD secFlags = SECURITY_FLAG_IGNORE_UNKNOWN_CA;
            WinHttpSetOption(hRequest, WINHTTP_OPTION_SECURITY_FLAGS, &secFlags, sizeof(secFlags));
        }

        // Upgrade: CompleteUpgrade сам доводит handshake до 101; при отказе
        // статус ответа доступен через QueryHeaders (401 invalid_agent_key
        // и т.п. — не ретраим быстро).
        HINTERNET hWs = WinHttpWebSocketCompleteUpgrade(hRequest, 0);
        if (!hWs) {
            m_httpStatus = QueryStatusCode(hRequest);
            Log(L"WS upgrade не прошёл (http=%lu)", m_httpStatus);
            WinHttpCloseHandle(hRequest);
            m_lastFatalAuth = (m_httpStatus == 401 || m_httpStatus == 403);
            return false;
        }
        // CompleteUpgrade возвращает НОВУЮ WS-ручку; hRequest больше не нужен.
        m_hWs = hWs;
        WinHttpCloseHandle(hRequest);
        m_connectedAt = GetTickCount64();
        Log(L"туннель до ядра установлен");
        return true;
    }

    DWORD httpStatus() const { return m_httpStatus; }
    bool lastFatalAuth() const { return m_lastFatalAuth; }

    ULONGLONG UptimeMs() const { return GetTickCount64() - m_connectedAt; }

    // Приём до разрыва (блокирующий WinHttpWebSocketReceive на sync-ручке;
    // Teardown() из другого потока разблокирует закрытием ручки).
    void Run() {
        m_ping = std::thread([this] { PingLoop(); });
        std::vector<char> buf(kRecvBuf);
        std::string pending; // склейка фрагментов одного сообщения
        for (;;) {
            if (m_stopped.load()) return;
            WINHTTP_WEB_SOCKET_BUFFER_TYPE type = (WINHTTP_WEB_SOCKET_BUFFER_TYPE)0;
            DWORD read = 0;
            DWORD err = WinHttpWebSocketReceive(m_hWs, buf.data(), (DWORD)buf.size(), &read, &type);
            if (err != NO_ERROR) {
                if (!m_stopped.load()) Log(L"WS-туннель разорван (err=%lu)", err);
                return;
            }
            switch (type) {
            case WINHTTP_WEB_SOCKET_BINARY_MESSAGE_BUFFER_TYPE:
                pending.append(buf.data(), read);
                HandleBinary(pending);
                pending.clear();
                break;
            case WINHTTP_WEB_SOCKET_BINARY_FRAGMENT_BUFFER_TYPE:
                pending.append(buf.data(), read);
                break;
            case WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE:
            case WINHTTP_WEB_SOCKET_UTF8_FRAGMENT_BUFFER_TYPE:
                pending.append(buf.data(), read);
                if (type == WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE) {
                    HandleText(pending);
                    pending.clear();
                }
                break;
            case WINHTTP_WEB_SOCKET_CLOSE_BUFFER_TYPE:
                Log(L"ядро закрыло туннель (close-кадр)");
                return;
            default:
                pending.clear();
                break;
            }
        }
    }

    void Teardown() {
        m_stopped.store(true);
        if (m_ping.joinable()) m_ping.join();
        CloseAllStreams();
        if (m_hWs) { WinHttpCloseHandle(m_hWs); m_hWs = nullptr; }
        if (m_hConnect) { WinHttpCloseHandle(m_hConnect); m_hConnect = nullptr; }
        if (m_hSession) { WinHttpCloseHandle(m_hSession); m_hSession = nullptr; }
    }

private:
    static const DWORD kRecvBuf = 256 * 1024;

    Config m_cfg;
    HINTERNET m_hSession = nullptr;
    HINTERNET m_hConnect = nullptr;
    HINTERNET m_hWs = nullptr;
    std::atomic<bool> m_stopped{false};
    std::thread m_ping;
    ULONGLONG m_connectedAt = 0;
    DWORD m_httpStatus = 0;
    bool m_lastFatalAuth = false;

    std::mutex m_sendMu;                     // единый писатель WS (серилизует кадры стримов)
    std::mutex m_streamsMu;
    std::map<unsigned long long, StreamCtx*> m_streams; // владелец ctx — его reader-поток

    static DWORD QueryStatusCode(HINTERNET hRequest) {
        DWORD code = 0, size = sizeof(code);
        WinHttpQueryHeaders(hRequest, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
            WINHTTP_HEADER_NAME_BY_INDEX, &code, &size, WINHTTP_NO_HEADER_INDEX);
        return code;
    }

    bool WsSendRaw(WINHTTP_WEB_SOCKET_BUFFER_TYPE bufType, const void* p, DWORD n) {
        std::lock_guard<std::mutex> lk(m_sendMu);
        if (!m_hWs || m_stopped.load()) return false;
        return WinHttpWebSocketSend(m_hWs, bufType, (PVOID)p, n) == NO_ERROR;
    }

    bool WsSendText(const std::string& s) {
        return WsSendRaw(WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE, s.data(), (DWORD)s.size());
    }

    // ---- контрольные кадры ядра ----

    void HandleText(const std::string& json) {
        std::string type = JsonExtractString(json, "type");
        unsigned long long sid = 0;
        JsonExtractU64(json, "stream_id", sid);
        if (type == "agent_hello") {
            Log(L"ядро приветствовало: endpoint=%S", JsonExtractString(json, "endpoint_id").c_str());
        } else if (type == "agent_assertion") {
            // Одноразовое окно CP-гейта для этого claim гранта (P1 #2).
            std::string nonce = JsonExtractString(json, "nonce");
            unsigned long long ttl = 0;
            JsonExtractU64(json, "expires_in", ttl);
            if (nonce.empty() || ttl == 0) {
                Log(L"agent_assertion без nonce/ttl — игнорирую");
            } else {
                StoreAssertionNonce(nonce, ttl);
                Log(L"assertion CP-гейта получен (ttl=%llu c)", ttl);
            }
        } else if (type == "agent_dial") {
            HandleDial(sid, json);
        } else if (type == "agent_close") {
            Log(L"ядро закрыло стрим %llu (%S)", sid, JsonExtractString(json, "reason").c_str());
            KillStream(sid);
        } else if (type == "pong") {
            // app-level heartbeat ответ — ничего не делаем
        }
    }

    void HandleDial(unsigned long long sid, const std::string& json) {
        // LOOPBACK ENFORCEMENT: host/port из кадра игнорируются — набор
        // всегда 127.0.0.1:targetPort (allowlist зашит, план §4.2).
        std::string host = JsonExtractString(json, "host");
        unsigned long long port = 0;
        JsonExtractU64(json, "port", port);
        Log(L"agent_dial стрим %llu (кадр host=%S port=%llu → набираю 127.0.0.1:%d)",
            sid, host.c_str(), port, m_cfg.targetPort);

        SOCKET s = DialLoopback(m_cfg.targetPort);
        if (s == INVALID_SOCKET) {
            WsSendText("{\"type\":\"agent_error\",\"stream_id\":" + std::to_string(sid) +
                       ",\"error\":\"local_rdp_unreachable\"}");
            Log(L"стрим %llu: 127.0.0.1:%d недоступен (WSA %d)", sid, m_cfg.targetPort, WSAGetLastError());
            return;
        }
        auto* ctx = new StreamCtx();
        ctx->id = sid;
        ctx->sock = s;
        {
            std::lock_guard<std::mutex> lk(m_streamsMu);
            m_streams[sid] = ctx;
        }
        if (!WsSendText("{\"type\":\"agent_opened\",\"stream_id\":" + std::to_string(sid) + "}")) {
            KillStream(sid);
            return;
        }
        // reader-поток стрима: TCP → бинарные кадры [8B id][data].
        // shared_ptr: сессия живёт, пока работает её последний reader —
        // Teardown() не ждёт reader'ы (они догрызают асинхронно), поэтому
        // владение разделяемое.
        std::thread([self = shared_from_this(), ctx] { self->StreamReader(ctx); }).detach();
    }

    // ---- бинарные кадры ядра → TCP ----

    void HandleBinary(const std::string& frame) {
        if (frame.size() < 8) return; // мусорный кадр без заголовка stream_id
        unsigned long long sid = 0;
        for (int i = 0; i < 8; i++) sid = (sid << 8) | (unsigned char)frame[i];
        StreamCtx* ctx = nullptr;
        {
            std::lock_guard<std::mutex> lk(m_streamsMu);
            auto it = m_streams.find(sid);
            if (it != m_streams.end()) ctx = it->second;
        }
        if (!ctx || ctx->closedByUs.load()) {
            // Неизвестный стрим: гасим сторону ядла без нового TCP (план §6).
            WsSendText("{\"type\":\"agent_close\",\"stream_id\":" + std::to_string(sid) +
                       ",\"reason\":\"unknown_stream\"}");
            return;
        }
        const char* data = frame.data() + 8;
        size_t n = frame.size() - 8;
        size_t off = 0;
        while (off < n) {
            int w = send(ctx->sock, data + off, (int)(n - off), 0);
            if (w <= 0) {
                KillStream(sid);
                SendAgentClose(sid, "tcp_write_failed");
                return;
            }
            off += (size_t)w;
        }
    }

    // ---- стримы ----

    void StreamReader(StreamCtx* ctx) {
        std::vector<char> buf(32 * 1024 + 8); // [8B id][данные] — как agentChunkSize ядра
        for (;;) {
            int n = recv(ctx->sock, buf.data() + 8, 32 * 1024, 0);
            if (n <= 0) break;
            for (int i = 0; i < 8; i++) buf[i] = (char)((ctx->id >> (56 - 8 * i)) & 0xFF);
            if (!WsSendRaw(WINHTTP_WEB_SOCKET_BINARY_MESSAGE_BUFFER_TYPE, buf.data(), (DWORD)(n + 8))) {
                break; // туннель мёртв — TCP закроется CloseAllStreams
            }
        }
        if (!ctx->closedByUs.load()) {
            SendAgentClose(ctx->id, "tcp_eof");
        }
        {
            std::lock_guard<std::mutex> lk(m_streamsMu);
            auto it = m_streams.find(ctx->id);
            if (it != m_streams.end() && it->second == ctx) m_streams.erase(it);
        }
        if (ctx->sock != INVALID_SOCKET) closesocket(ctx->sock);
        delete ctx; // владелец — этот поток
    }

    void SendAgentClose(unsigned long long sid, const char* reason) {
        WsSendText("{\"type\":\"agent_close\",\"stream_id\":" + std::to_string(sid) +
                   ",\"reason\":\"" + std::string(reason) + "\"}");
    }

    // Закрыть стрим со стороны агента (TCP рвётся, reader сам догрызёт).
    void KillStream(unsigned long long sid) {
        StreamCtx* ctx = nullptr;
        {
            std::lock_guard<std::mutex> lk(m_streamsMu);
            auto it = m_streams.find(sid);
            if (it == m_streams.end()) return;
            ctx = it->second;
            m_streams.erase(it);
        }
        ctx->closedByUs.store(true);
        if (ctx->sock != INVALID_SOCKET) closesocket(ctx->sock);
        // ctx освободит свой reader-поток
    }

    void CloseAllStreams() {
        std::vector<StreamCtx*> list;
        {
            std::lock_guard<std::mutex> lk(m_streamsMu);
            for (auto& kv : m_streams) list.push_back(kv.second);
            m_streams.clear();
        }
        for (auto* ctx : list) {
            ctx->closedByUs.store(true);
            if (ctx->sock != INVALID_SOCKET) closesocket(ctx->sock);
        }
        // reader-потоки разбужаются закрытым сокетом и сами удалят ctx
    }

    // ---- сердцебиение app-level (поверх WS ping/pong WinHTTP) ----

    void PingLoop() {
        for (;;) {
            for (int ms = 0; ms < kPingEveryMs; ms += 200) {
                if (m_stopped.load()) return;
                Sleep(200);
            }
            if (m_stopped.load()) return;
            if (!WsSendText("{\"type\":\"ping\"}")) return;
        }
    }

    // ---- TCP до локального RDP (connect с таймаутом) ----

    static SOCKET DialLoopback(int port) {
        SOCKADDR_IN sa = {0};
        sa.sin_family = AF_INET;
        sa.sin_port = htons((u_short)port);
        sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        SOCKET s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        if (s == INVALID_SOCKET) return INVALID_SOCKET;
        u_long nb = 1;
        ioctlsocket(s, FIONBIO, &nb);
        connect(s, (sockaddr*)&sa, sizeof(sa));
        fd_set w;
        FD_ZERO(&w);
        FD_SET(s, &w);
        timeval tv = {kDialTimeoutSec, 0};
        if (select(0, nullptr, &w, nullptr, &tv) > 0) {
            int soerr = 0;
            int len = sizeof(soerr);
            getsockopt(s, SOL_SOCKET, SO_ERROR, (char*)&soerr, &len);
            if (soerr == 0) {
                u_long b = 0;
                ioctlsocket(s, FIONBIO, &b);
                // NODELAY: интерактивный RDP-поток, задержка Nagle недопустима.
                int nodelay = 1;
                setsockopt(s, IPPROTO_TCP, TCP_NODELAY, (const char*)&nodelay, sizeof(nodelay));
                return s;
            }
        }
        closesocket(s);
        return INVALID_SOCKET;
    }
};

// ---------------- Рабочий цикл службы ----------------

void WorkerLoop() {
    WSADATA wsa = {0};
    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) {
        Log(L"WSAStartup failed");
        return;
    }

    // Named pipe CP-гейта живёт всю жизнь службы (не привязан к туннелю):
    // assertion-окно переживает реконнекты WSS.
    std::thread gatePipe(RdpGatePipeLoop, g_hStop);

    // 1с → 2с → … → капа 60с, джиттер ±20% (порт ws_service.ReconnectBackoff).
    ReconnectBackoff backoff(1000, 60000, 0.2);
    bool loggedNoConfig = false;

    while (WaitForSingleObject(g_hStop, 0) == WAIT_TIMEOUT) {
        Config cfg;
        if (!LoadConfig(cfg) || !cfg.Valid()) {
            if (!loggedNoConfig) {
                Log(L"конфигурация неполна (ServerURL/RdpAgentKey/RdpAgentEnabled) — служба пассивна");
                loggedNoConfig = true;
            }
            if (WaitForSingleObject(g_hStop, 30000) != WAIT_TIMEOUT) break;
            continue;
        }
        loggedNoConfig = false;

        {
            auto session = std::make_shared<AgentSession>(cfg);
            if (session->Connect()) {
                session->Run(); // до разрыва туннеля
                // Стабильность ≥60с — следующий обрыв стартует с 1с.
                if (session->UptimeMs() >= (ULONGLONG)kStableResetMs) {
                    backoff.Reset();
                }
            } else if (session->lastFatalAuth()) {
                // 401 invalid_agent_key / 403 endpoint_disabled — ретраить
                // бессмысленно до действий админа; длинная пауза 5 мин.
                Log(L"невалидный/отключённый agent_key — повтор через 5 мин");
                if (WaitForSingleObject(g_hStop, 300000) != WAIT_TIMEOUT) break;
                continue;
            }
        }

        if (WaitForSingleObject(g_hStop, 0) != WAIT_TIMEOUT) break;
        const int delay = backoff.NextDelayMs();
        Log(L"переподключение через %d мс", delay);
        if (WaitForSingleObject(g_hStop, (DWORD)delay) != WAIT_TIMEOUT) break;
    }

    gatePipe.join();
    WSACleanup();
    Log(L"служба остановлена");
}

// ---------------- SCM ----------------

void WINAPI SvcHandler(DWORD control) {
    switch (control) {
    case SERVICE_CONTROL_STOP:
    case SERVICE_CONTROL_SHUTDOWN:
        g_status.dwCurrentState = SERVICE_STOP_PENDING;
        g_status.dwWaitHint = 8000;
        SetServiceStatus(g_hStatus, &g_status);
        if (g_hStop) SetEvent(g_hStop);
        break;
    default:
        SetServiceStatus(g_hStatus, &g_status);
    }
}

void WINAPI SvcMain(DWORD argc, wchar_t** argv) {
    UNREFERENCED_PARAMETER(argc);
    UNREFERENCED_PARAMETER(argv);
    g_hStatus = RegisterServiceCtrlHandlerW(kSvcName, SvcHandler);
    if (!g_hStatus) return;

    g_status.dwServiceType = SERVICE_WIN32_OWN_PROCESS;
    g_status.dwCurrentState = SERVICE_START_PENDING;
    g_status.dwControlsAccepted = SERVICE_ACCEPT_STOP | SERVICE_ACCEPT_SHUTDOWN;
    SetServiceStatus(g_hStatus, &g_status);

    g_hStop = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    g_status.dwCurrentState = SERVICE_RUNNING;
    SetServiceStatus(g_hStatus, &g_status);
    Log(L"endpoint-служба запущена (pid=%lu, version=%S)", GetCurrentProcessId(), kAgentVersion);

    WorkerLoop();

    g_status.dwCurrentState = SERVICE_STOPPED;
    SetServiceStatus(g_hStatus, &g_status);
    if (g_hStop) CloseHandle(g_hStop);
}

} // namespace

int wmain(int argc, wchar_t** argv) {
    if (argc > 1 && wcscmp(argv[1], L"--console") == 0) {
        // Отладка без SCM: g_hStop не создан → WaitForSingleObject(nullptr, …)
        // вернёт WAIT_FAILED, поэтому создадим событие и погоняем один цикл.
        g_hStop = CreateEventW(nullptr, TRUE, FALSE, nullptr);
        printf("Ligament Endpoint Service (console mode)\n");
        WorkerLoop();
        return 0;
    }
    SERVICE_TABLE_ENTRYW table[] = {
        {const_cast<LPWSTR>(kSvcName), SvcMain},
        {nullptr, nullptr},
    };
    if (!StartServiceCtrlDispatcherW(table)) {
        Log(L"StartServiceCtrlDispatcherW failed %lu", GetLastError());
        return 1;
    }
    return 0;
}
