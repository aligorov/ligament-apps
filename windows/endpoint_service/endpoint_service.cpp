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
//                  RDP-02: nonce вяжется к logon_id запросившего окна —
//                  чужое окно входа его не получит.
//   ядро → агент: {"type":"agent_console_wake","session_id":"<uuid>",
//                  "machine_id":"<uuid>"} — Ш5 плана console-any-state:
//                  юзер вошёл, приложение закрыто — поднять
//                  ligament_authenticator.exe в консольной сессии
//                  (--minimized --autoshare=<session_id>). machine_id
//                  агентом игнорируется: соединение уже привязано ядром
//                  к этому endpoint по agent_key.
//   агент → ядро: {"type":"agent_console_wake_result","session_id":"<uuid>",
//                  "spawned":true|false,"reason":"launched"|
//                  "already_running"|"no_user_session"|"no_user_token"|
//                  "spawn_failed"} — ответ до таймаута ядра (~10с).
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
#include <wtsapi32.h>   // WTSGetActiveConsoleSessionId / WTSQueryUserToken (Ш5)
#include <tlhelp32.h>   // Toolhelp-снапшот: ligament_authenticator уже в сессии?
#include <userenv.h>    // CreateEnvironmentBlock (Ш5: окружение пользователя)
#include "console_host_process.h" // Ш6: SYSTEM-воркер консоли в сессии Winlogon/LogonUI
#include <stdio.h>
#include <cctype>
#include <cwctype>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <deque>
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
#pragma comment(lib, "wtsapi32.lib") // WTSQueryUserToken (Ш5)
#pragma comment(lib, "userenv.lib")  // CreateEnvironmentBlock (Ш5)

namespace {

const wchar_t* kSvcName = L"LigamentEndpointService";
const wchar_t* kAppExe = L"ligament_authenticator.exe"; // будим Ш5 (как service.cpp)
// Версия агента пробрасывается из pubspec.yaml при сборке MSI
// (build_msi.ps1 → cmake -DLIGAMENT_AGENT_VERSION). «dev» — локальная
// сборка без define: на сервере видно, что это не релизная служба.
#ifndef LigamentAgentVersion
#define LigamentAgentVersion "dev"
#endif
const char kAgentVersion[] = LigamentAgentVersion;
const int kStableResetMs = 60000;   // сброс backoff после минуты стабильности
const int kPingEveryMs = 25000;     // app-level ping (сердцебиение ниже WS-пингов WinHTTP)
const int kDialTimeoutSec = 4;      // connect до 127.0.0.1:3389
// Лимит очереди ядро→TCP на один стрим (RDP-14): перестоявший RDP-сервер не
// имеет права заблокировать приём контрольных кадров (agent_close и пр.).
// Переполнение — лог + закрытие стрима.
const size_t kStreamQueueMaxBytes = 4 * 1024 * 1024;

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
    std::wstring deviceId;
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
    ReadRegString(L"RdpDeviceId", cfg.deviceId);
    if (cfg.deviceId.empty()) ReadRegString(L"DeviceId", cfg.deviceId);
    DWORD v = 0;
    if (ReadRegDword(L"RdpAgentEnabled", v)) cfg.enabled = (v != 0);
    if (ReadRegDword(L"AllowSelfSigned", v)) cfg.allowSelfSigned = (v != 0);
    if (ReadRegDword(L"AllowHttp", v)) cfg.allowHttp = (v != 0);
    if (ReadRegDword(L"RdpAgentTargetPort", v) && v > 0 && v < 65536) cfg.targetPort = (int)v;
    // Trim
    while (!cfg.serverUrl.empty() && iswspace(cfg.serverUrl.back())) cfg.serverUrl.pop_back();
    while (!cfg.serverUrl.empty() && iswspace(cfg.serverUrl.front())) cfg.serverUrl.erase(0, 1);
    while (!cfg.deviceId.empty() && iswspace(cfg.deviceId.back())) cfg.deviceId.pop_back();
    while (!cfg.deviceId.empty() && iswspace(cfg.deviceId.front())) cfg.deviceId.erase(0, 1);
    return cfg.Valid();
}

// ---------------- Assertion CP-гейта (nonce для Ligament-CP) ----------------
// Ядро после claim гранта (WS-труба юзера) присылает контрольный кадр
// agent_assertion с одноразовым nonce (сервер rdp_cp.go, миграция 0065:
// TTL 5 минут, одноразовость used_at, привязка к endpoint). Состояние —
// процесс-глобальное: переживает реконнект WSS-туннеля (служба жива,
// окно подключения никуда не девается). Протухший nonce не отдаётся.
//
// RDP-02 (аудит): nonce привязывается к КОНКРЕТНОМУ логон-окну Windows.
// Ядро logon_id знать не может, поэтому связка происходит при запросе CP:
// первый запрос named-pipe с параметрами входа (logon_id/username/
// user_sid) вяжет ожидающий nonce к этому logon_id; окно ДРУГОГО входа
// тот же nonce не получит (пустой ответ). Повторный запрос того же окна
// в пределах TTL получает тот же nonce — сетевой ретрай не жжёт окно.

const wchar_t* kRdpGatePipeName = L"\\\\.\\pipe\\LigamentRdpGate";

// Определение ниже (секция «Мини-JSON»); нужен уже в цикле pipe.
std::string JsonExtractString(const std::string& json, const char* key);

struct RdpAssertionEntry {
    std::string nonce;
    ULONGLONG expiresAtTick = 0; // GetTickCount64-дедлайн

    bool Live(ULONGLONG now) const { return !nonce.empty() && now < expiresAtTick; }
};

struct RdpAssertionState {
    std::mutex mu;
    // Ожидающий nonce (последний agent_assertion от ядра, ещё не привязан).
    RdpAssertionEntry pending;
    // Привязанные: logon_id → nonce (RDP-02: один nonce — одно окно входа).
    std::map<std::string, RdpAssertionEntry> bound;
};

RdpAssertionState g_assertion;

void StoreAssertionNonce(const std::string& nonce, unsigned long long expiresInSec) {
    std::lock_guard<std::mutex> lk(g_assertion.mu);
    g_assertion.pending.nonce = nonce;
    g_assertion.pending.expiresAtTick = GetTickCount64() + expiresInSec * 1000ULL;
    // Заодно вычищаем протухшие привязки (карта не растёт бесконечно).
    const ULONGLONG now = GetTickCount64();
    for (auto it = g_assertion.bound.begin(); it != g_assertion.bound.end();) {
        if (it->second.Live(now)) ++it;
        else it = g_assertion.bound.erase(it);
    }
}

// Ответ CP для КОНКРЕТНОГО логон-окна: живой bound-nonce этого окна, либо
// перевод ожидающего nonce в bound за этим окном, либо пустой nonce.
std::string AssertionJsonForLogon(const std::string& logonId, const std::string& username,
                                  const std::string& userSid) {
    std::string nonce;
    if (!logonId.empty()) {
        std::lock_guard<std::mutex> lk(g_assertion.mu);
        const ULONGLONG now = GetTickCount64();
        for (auto it = g_assertion.bound.begin(); it != g_assertion.bound.end();) {
            if (it->second.Live(now)) ++it;
            else it = g_assertion.bound.erase(it);
        }
        auto it = g_assertion.bound.find(logonId);
        if (it != g_assertion.bound.end() && it->second.Live(now)) {
            nonce = it->second.nonce; // ретрай того же окна в пределах TTL
        } else if (g_assertion.pending.Live(now)) {
            g_assertion.bound[logonId] = g_assertion.pending;
            nonce = g_assertion.pending.nonce;
            g_assertion.pending.nonce.clear();
            g_assertion.pending.expiresAtTick = 0;
            Log(L"assertion привязан к логон-окну %S (user=%S sid=%S)",
                logonId.c_str(), username.c_str(), userSid.c_str());
        }
    }
    if (nonce.empty()) return "{\"nonce\":\"\"}";
    return "{\"nonce\":\"" + nonce + "\"}";
}

// Цикл named pipe для CP (LigamentCredential, фаза 0). Протокол (RDP-02):
// CP подключается, ПИШЕТ один JSON-запрос с параметрами входа
//   {"logon_id":"<hex>","username":"...","user_sid":"S-1-..."}
// и ЧИТАЕТ ответ {"nonce":"<hex>|"} (пустой nonce — нет окна/чужое окно).
// DACL: SYSTEM и Администраторы (CP живёт в LogonUI/wlogon под SYSTEM;
// стандартный пользователь процесс-хендл не получает). Overlapped-подклю-
// чение ждёт ИЛИ клиента, ИЛИ stop-события службы — shutdown не виснет
// на Accept.
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
            // Запрос CP: параметры логон-окна (до 1 КиБ, таймаут 2 с).
            // TRUE = операция завершилась синхронно (событие может не
            // взводиться) — байты уже в буфере; иначе ждём событие.
            std::string req;
            char rbuf[1024];
            DWORD readN = 0;
            ResetEvent(ov.hEvent);
            BOOL okRd = ReadFile(hPipe, rbuf, sizeof(rbuf), &readN, &ov);
            if (okRd) {
                req.assign(rbuf, readN);
            } else if (GetLastError() == ERROR_IO_PENDING) {
                if (WaitForSingleObject(ov.hEvent, 2000) == WAIT_OBJECT_0 &&
                    GetOverlappedResult(hPipe, &ov, &readN, FALSE)) {
                    req.assign(rbuf, readN);
                } else {
                    // CP не прислал запрос (старый протокол/завис) — ниже
                    // уйдёт пустой nonce; отменить чтение и ДОЖДАТЬСЯ
                    // отмены, чтобы не гонять два перекрывающихся I/O.
                    CancelIo(hPipe);
                    DWORD dummy = 0;
                    GetOverlappedResult(hPipe, &ov, &dummy, TRUE);
                }
            }
            const std::string resp = AssertionJsonForLogon(
                JsonExtractString(req, "logon_id"),
                JsonExtractString(req, "username"),
                JsonExtractString(req, "user_sid"));
            DWORD written = 0;
            ResetEvent(ov.hEvent);
            BOOL okWr = WriteFile(hPipe, resp.data(), (DWORD)resp.size(), &written, &ov);
            if (!okWr && GetLastError() == ERROR_IO_PENDING) {
                if (WaitForSingleObject(ov.hEvent, 3000) == WAIT_OBJECT_0) {
                    GetOverlappedResult(hPipe, &ov, &written, FALSE);
                } else {
                    CancelIo(hPipe);
                    DWORD dummy = 0;
                    GetOverlappedResult(hPipe, &ov, &dummy, TRUE);
                }
            }
            FlushFileBuffers(hPipe);
            DisconnectNamedPipe(hPipe);
            Log(L"CP забрал assertion-гейт (запрос %zu байт, ответ %zu байт)",
                req.size(), resp.size());
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

// ---------------- Wake приложения в консольной сессии (Ш5) ----------------
// Кадр agent_console_wake (Ш5 плана docs/console-any-state-plan.md): юзер
// вошёл, приложение закрыто — поднять ligament_authenticator.exe в
// КОНСОЛЬНОЙ сессии (WTSGetActiveConsoleSessionId) с --autoshare=<sid>.
// Запуск — порт LaunchAppInSession из service.cpp с исправлением рецензии:
// CreateEnvironmentBlock(hToken) + CREATE_UNICODE_ENVIRONMENT вместо
// наследования LocalSystem-окружения службы.

// ligament_authenticator.exe уже жив в УКАЗАННОЙ сессии? (порт
// AppRunningInSession из service.cpp). Ошибка снапшота = «жив»: будить
// вслепую нельзя — риск второго экземпляра (план §8 «двойной запуск»).
bool AppRunningInSession(DWORD sessionId) {
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == INVALID_HANDLE_VALUE) return true; // не знаем — не спавним
    PROCESSENTRY32W pe = {};
    pe.dwSize = sizeof(pe);
    bool found = false;
    if (Process32FirstW(snap, &pe)) {
        do {
            if (_wcsicmp(pe.szExeFile, kAppExe) != 0) continue;
            DWORD pidSession = 0;
            if (ProcessIdToSessionId(pe.th32ProcessID, &pidSession) && pidSession == sessionId) {
                found = true;
                break;
            }
        } while (Process32NextW(snap, &pe));
    }
    CloseHandle(snap);
    return found;
}

// Проверка, запущен ли ligament_authenticator.exe в любой сессии на ПК
bool FindRunningAppSession(DWORD& outSessionId) {
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == INVALID_HANDLE_VALUE) return false;
    PROCESSENTRY32W pe = {};
    pe.dwSize = sizeof(pe);
    bool found = false;
    if (Process32FirstW(snap, &pe)) {
        do {
            if (_wcsicmp(pe.szExeFile, kAppExe) != 0) continue;
            DWORD pidSession = 0;
            if (ProcessIdToSessionId(pe.th32ProcessID, &pidSession)) {
                outSessionId = pidSession;
                found = true;
                break;
            }
        } while (Process32NextW(snap, &pe));
    }
    CloseHandle(snap);
    return found;
}

// A-04 (аудит 2026-10-10): Доставка намерения autoshare работающему приложению через loopback HTTP-порт 8757
bool DeliverAutoshareToRunningApp(const std::string& sessionId) {
    SOCKET s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (s == INVALID_SOCKET) return false;

    DWORD tv = 2000;
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, (const char*)&tv, sizeof(tv));
    setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, (const char*)&tv, sizeof(tv));

    sockaddr_in sa = {};
    sa.sin_family = AF_INET;
    sa.sin_port = htons(8757);
    sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

    if (connect(s, (sockaddr*)&sa, sizeof(sa)) != 0) {
        closesocket(s);
        return false;
    }

    std::string body = "{\"session_id\":\"" + sessionId + "\"}";
    std::string req = "POST /autoshare HTTP/1.1\r\n"
                      "Host: 127.0.0.1:8757\r\n"
                      "Content-Type: application/json\r\n"
                      "Content-Length: " + std::to_string(body.size()) + "\r\n"
                      "Connection: close\r\n\r\n" + body;

    int sent = send(s, req.c_str(), (int)req.size(), 0);
    if (sent != (int)req.size()) {
        closesocket(s);
        return false;
    }

    char buf[512] = {0};
    int recvd = recv(s, buf, sizeof(buf) - 1, 0);
    closesocket(s);

    if (recvd > 0) {
        buf[recvd] = 0;
        if (strstr(buf, "200 OK") != nullptr || strstr(buf, "HTTP/1.1 200") != nullptr) {
            return true;
        }
    }
    return false;
}

// Запуск приложения в пользовательской сессии (порт LaunchAppInSession из
// service.cpp; hToken уже запрошен вызывающим через WTSQueryUserToken —
// отдельный шаг с отдельным кодом ошибки no_user_token).
bool SpawnAppInSession(HANDLE hToken, DWORD sessionId, const std::wstring& autoshare) {
    // exe службы лежит рядом с приложением (один INSTALLFOLDER)
    wchar_t exePath[MAX_PATH] = {0};
    GetModuleFileNameW(nullptr, exePath, MAX_PATH);
    wchar_t* slash = wcsrchr(exePath, L'\\');
    if (slash) *(slash + 1) = 0;
    wchar_t appPath[MAX_PATH] = {0};
    swprintf_s(appPath, L"%s%s", exePath, kAppExe);

    STARTUPINFOW si = {};
    si.cb = sizeof(si);
    si.lpDesktop = (LPWSTR)L"winsta0\\default"; // рабочий стол пользователя
    // Буфер с запасом: путь ≤ MAX_PATH + « --minimized --autoshare=» + UUID.
    wchar_t args[MAX_PATH + 96] = {0};
    _snwprintf_s(args, _countof(args), _TRUNCATE,
                 L"\"%s\" --minimized --autoshare=%s", appPath, autoshare.c_str());

    // Рецензия Ш5: CreateProcessAsUserW с lpEnvironment=NULL наследует
    // окружение СЛУЖБЫ (LocalSystem) — у приложения пользователя ломаются
    // %APPDATA%/%LOCALAPPDATA%. Берём окружение из ЕГО токена.
    LPVOID env = nullptr;
    if (!CreateEnvironmentBlock(&env, hToken, TRUE)) {
        env = nullptr; // fallback — унаследовать окружение службы
        Log(L"console_wake: CreateEnvironmentBlock failed %lu — окружение службы",
            GetLastError());
    }
    PROCESS_INFORMATION pi = {};
    BOOL ok = CreateProcessAsUserW(hToken, appPath, args, nullptr, nullptr,
        FALSE, env ? CREATE_UNICODE_ENVIRONMENT : 0, env, nullptr, &si, &pi);
    if (!ok) {
        // Fallback на winsta0\Winlogon (экран блокировки / экран входа Windows)
        si.lpDesktop = (LPWSTR)L"winsta0\\Winlogon";
        ok = CreateProcessAsUserW(hToken, appPath, args, nullptr, nullptr,
            FALSE, env ? CREATE_UNICODE_ENVIRONMENT : 0, env, nullptr, &si, &pi);
    }
    if (env) DestroyEnvironmentBlock(env);
    if (ok) {
        Log(L"console_wake: клиент запущен в сессии %lu (pid %lu)", sessionId, pi.dwProcessId);
        CloseHandle(pi.hThread);
        CloseHandle(pi.hProcess);
    } else {
        Log(L"console_wake: CreateProcessAsUserW failed %lu", GetLastError());
    }
    return ok != FALSE;
}

// ---------------- Агентская сессия ----------------

// Контекст одного стрима (пара TCP↔WS-кадры). Владение — shared_ptr
// (RDP-09): карта стримов и reader/writer-потоки держат по копии, поэтому
// удаление из карты не освобождает объект под ногами работающего потока.
struct StreamCtx {
    unsigned long long id = 0;

    // ЕДИНСТВЕННОЕ закрытие сокета (RDP-09): atomic compare_exchange не
    // пускает второго closesocket, хэндл зануляется под тем же локом —
    // двойного закрытия и попадания переиспользованного хэндла в send/recv
    // нет. send/recv по снапшоту БЕЗ удержания lock'а — closesocket из
    // другого потока разбивает блокированный вызов, не дедлочась на мьютексе.
    std::mutex sockMu;
    SOCKET sock = INVALID_SOCKET;
    std::atomic<bool> sockClosed{false};
    // Стрим погашен (KillStream/ошибка/Teardown): данные больше не ходят.
    std::atomic<bool> dead{false};

    // Очередь ядро→TCP с лимитом (RDP-14): Run-поток только ставит в
    // очередь и никогда не блокируется на send — контрольный канал
    // (agent_close) не стоит за данными. Отправку выносит writer-поток.
    std::mutex qMu;
    std::condition_variable qCv;
    std::deque<std::string> q;
    size_t queuedBytes = 0;
    bool qAbort = false; // writer: завершиться (сокет закрыт/стрим погашен)

    SOCKET SockSnapshot() {
        std::lock_guard<std::mutex> lk(sockMu);
        return sock;
    }

    void WakeWriter() {
        {
            std::lock_guard<std::mutex> lk(qMu);
            qAbort = true;
        }
        qCv.notify_all();
    }

    // Закрыть сокет РОВНО ОДИН РАЗ; последующие вызовы — no-op, но writer
    // всё равно разбужены (идемпотентно).
    void CloseSocketOnce() {
        bool already = false;
        if (!sockClosed.compare_exchange_strong(already, true)) {
            WakeWriter();
            return;
        }
        SOCKET s = INVALID_SOCKET;
        {
            std::lock_guard<std::mutex> lk(sockMu);
            s = sock;
            sock = INVALID_SOCKET; // зануляем тем же локом, что и закрываем
        }
        dead.store(true);
        if (s != INVALID_SOCKET) closesocket(s);
        WakeWriter();
    }

    // Поставить данные в очередь writer'а. false — переполнение лимита
    // (RDP-14): вызывающий обязан погасить стрим. true при qAbort — дроп
    // молча (стрим уже гасится).
    bool Enqueue(std::string&& payload) {
        {
            std::lock_guard<std::mutex> lk(qMu);
            if (qAbort) return true;
            if (queuedBytes + payload.size() > kStreamQueueMaxBytes) return false;
            queuedBytes += payload.size();
            q.push_back(std::move(payload));
        }
        qCv.notify_one();
        return true;
    }

    ~StreamCtx() {
        // Страховка: если никто не позвал CloseSocketOnce — закрыть здесь.
        if (!sockClosed.exchange(true)) {
            std::lock_guard<std::mutex> lk(sockMu);
            if (sock != INVALID_SOCKET) {
                closesocket(sock);
                sock = INVALID_SOCKET;
            }
        }
    }
};

class AgentSession : public std::enable_shared_from_this<AgentSession> {
public:
    explicit AgentSession(const Config& cfg) : m_cfg(cfg) {}

    ~AgentSession() {
        Teardown();
        // Родительские ручки — только здесь: все потоки сессии (watcher,
        // ping, стримы через shared_from_this) уже завершились или держат
        // лишь свои копии shared_ptr и не заходят в WinHTTP после Teardown.
        if (m_hConnect) { WinHttpCloseHandle(m_hConnect); m_hConnect = nullptr; }
        if (m_hSession) { WinHttpCloseHandle(m_hSession); m_hSession = nullptr; }
    }

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
        // resolve/connect/send — таймауты установления; receive ограничивает
        // ожидание статуса 101 (сам WinHttpWebSocketReceive таймаутов не
        // имеет — разрыв контролирует stop-watcher в Run, RDP-14).
        WinHttpSetTimeouts(m_hSession, 5000, 10000, 15000, 20000);

        m_hConnect = WinHttpConnect(m_hSession, host, uc.nPort, 0);
        if (!m_hConnect) return false;

        // В query — только version (не секрет). agent_key — заголовком
        // Authorization Bearer: контракт rdp_agent_hub.HandleConnect читает
        // ключ из заголовка (аудит P2 2026-10-08 — креды в query оседают в
        // access-логах прокси и трассировке ядра).
        std::wstring path = L"/api/v1/rdp/agent/connect?version=" +
            Utf8ToWide(kAgentVersion);
        if (!m_cfg.deviceId.empty()) {
            path += L"&device_id=" + m_cfg.deviceId;
        }
        // Имя машины (UTF-8 + percent-encoding): ядро v0.8.162 показывает его
        // в списке машин; без него endpoint безымянный «Endpoint <uuid>».
        {
            wchar_t hostBuf[256];
            DWORD hostLen = (DWORD)(sizeof(hostBuf) / sizeof(hostBuf[0]));
            if (GetComputerNameW(hostBuf, &hostLen)) {
                const std::string utf8 = WideToUtf8(std::wstring(hostBuf, hostLen));
                static const char* kHex = "0123456789ABCDEF";
                std::wstring enc;
                enc.reserve(utf8.size() * 3);
                for (unsigned char c : utf8) {
                    if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                        (c >= '0' && c <= '9') || c == '-' || c == '.' || c == '_') {
                        enc += (wchar_t)c;
                    } else {
                        enc += L'%';
                        enc += (wchar_t)kHex[(c >> 4) & 0xF];
                        enc += (wchar_t)kHex[c & 0xF];
                    }
                }
                if (!enc.empty()) {
                    path += L"&hostname=" + enc;
                }
            }
        }
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

        // Редиректы запрещены (RDP-07): агентский WSS-эндпоинт не переезжает,
        // автоматический переход сорвал бы апгрейд и молча унёс бы
        // Authorization на чужой хост.
        DWORD noRedirects = WINHTTP_DISABLE_REDIRECTS;
        WinHttpSetOption(hRequest, WINHTTP_OPTION_DISABLE_FEATURE,
            &noRedirects, sizeof(noRedirects));

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

        // RDP-07: ручка ПОМЕЧАЕТСЯ на WebSocket-upgrade ДО отправки запроса
        // (официальная последовательность nf-winhttp-winhttpwebsocketcomplete-
        // upgrade; опция параметров не принимает — сэмпл Microsoft передаёт
        // NULL/0). Раньше CompleteUpgrade звался сразу после AddHeaders —
        // handshake при этом вообще не отправлялся.
        if (!WinHttpSetOption(hRequest, WINHTTP_OPTION_UPGRADE_TO_WEB_SOCKET, nullptr, 0)) {
            Log(L"WINHTTP_OPTION_UPGRADE_TO_WEB_SOCKET не принята (%lu)", GetLastError());
            WinHttpCloseHandle(hRequest);
            return false;
        }

        // Отправка handshake и приём ответа: Upgrade: websocket /
        // Sec-WebSocket-Key WinHTTP добавляет сам; Authorization уже стоит
        // на ручке (AddRequestHeaders выше, до отправки).
        if (!WinHttpSendRequest(hRequest, WINHTTP_NO_ADDITIONAL_HEADERS, 0,
                                WINHTTP_NO_REQUEST_DATA, 0, 0, 0)) {
            Log(L"WS handshake: WinHttpSendRequest не прошёл (%lu)", GetLastError());
            WinHttpCloseHandle(hRequest);
            return false;
        }
        if (!WinHttpReceiveResponse(hRequest, nullptr)) {
            Log(L"WS handshake: WinHttpReceiveResponse не прошёл (%lu)", GetLastError());
            WinHttpCloseHandle(hRequest);
            return false;
        }

        // 101 Switching Protocols — единственный статус, при котором доку-
        // ментация разрешает CompleteUpgrade. 401 invalid_agent_key / 403
        // endpoint_disabled и любые прочие коды — лог, разрыв, backoff выше
        // (фатальные по auth — длинная пауза в WorkerLoop).
        m_httpStatus = QueryStatusCode(hRequest);
        if (m_httpStatus != 101) {
            Log(L"WS upgrade отклонён ядром (http=%lu)", m_httpStatus);
            WinHttpCloseHandle(hRequest);
            m_lastFatalAuth = (m_httpStatus == 401 || m_httpStatus == 403);
            return false;
        }

        HINTERNET hWs = WinHttpWebSocketCompleteUpgrade(hRequest, 0);
        if (!hWs) {
            Log(L"WinHttpWebSocketCompleteUpgrade не прошёл (%lu)", GetLastError());
            WinHttpCloseHandle(hRequest);
            return false;
        }
        // CompleteUpgrade возвращает НОВУЮ WS-ручку; hRequest больше не нужен.
        {
            std::lock_guard<std::mutex> lk(m_wsMu);
            m_hWs = hWs;
        }
        WinHttpCloseHandle(hRequest);
        m_connectedAt = GetTickCount64();
        Log(L"туннель до ядра установлен");
        return true;
    }

    DWORD httpStatus() const { return m_httpStatus; }
    bool lastFatalAuth() const { return m_lastFatalAuth; }

    ULONGLONG UptimeMs() const { return GetTickCount64() - m_connectedAt; }

    // Приём до разрыва. Синхронный WinHttpWebSocketReceive таймаутов не
    // имеет: SCM STOP выставляет g_hStop, но Run об этом не узнал бы, пока
    // жив туннель. Поэтому RDP-14: отдельный stop-watcher-поток ждёт
    // g_hStop и рвёт WSS-ручку (Teardown) — закрытие хэндла выталкивает
    // заблокированный Receive ошибкой, служба останавливается за секунды.
    void Run() {
        HANDLE hDone = CreateEventW(nullptr, TRUE, FALSE, nullptr); // manual-reset
        std::thread watcher;
        if (hDone) {
            watcher = std::thread([this, hDone] {
                HANDLE waits[2] = { g_hStop, hDone };
                DWORD w = WaitForMultipleObjects(2, waits, FALSE, INFINITE);
                if (w == WAIT_OBJECT_0) Teardown(); // SCM STOP/SHUTDOWN
            });
        } else {
            Log(L"CreateEvent(run-done) failed — без stop-watcher (%lu)", GetLastError());
        }
        m_ping = std::thread([this] { PingLoop(); });
        std::vector<char> buf(kRecvBuf);
        std::string pending; // склейка фрагментов одного сообщения
        for (;;) {
            if (m_stopped.load()) break;
            HINTERNET hWs = nullptr;
            {
                std::lock_guard<std::mutex> lk(m_wsMu);
                hWs = m_hWs;
            }
            if (!hWs) break; // ручка закрыта (Teardown из watcher'а)
            WINHTTP_WEB_SOCKET_BUFFER_TYPE type = (WINHTTP_WEB_SOCKET_BUFFER_TYPE)0;
            DWORD read = 0;
            DWORD err = WinHttpWebSocketReceive(hWs, buf.data(), (DWORD)buf.size(), &read, &type);
            if (err != NO_ERROR) {
                if (!m_stopped.load()) Log(L"WS-туннель разорван (err=%lu)", err);
                break;
            }
            bool stopLoop = false;
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
                stopLoop = true;
                break;
            default:
                pending.clear();
                break;
            }
            if (stopLoop) break;
        }
        // Будим watcher (естественный разрыв) и ждём его выхода: после
        // join никто не троннет сессию/ручки параллельно с деструктором.
        if (hDone) {
            SetEvent(hDone);
            if (watcher.joinable()) watcher.join();
            CloseHandle(hDone);
        }
    }

    // Разрыв туннеля. Идемпотентна и потокобезопасна: приходит из
    // stop-watcher (RDP-14), из Run и из деструктора. Закрывает WSS-ручку
    // и стримы; hConnect/hSession закрывает только деструктор — после
    // смерти всех потоков сессии, чтобы родительские ручки не закрылись
    // под работающим Receive.
    void Teardown() {
        m_stopped.store(true);
        // Сначала рвём WSS-ручку: это разбивает и вечный Receive в Run, и
        // застрявший send в PingLoop/стримах — join'ы ниже проходят быстро.
        {
            std::lock_guard<std::mutex> lk(m_wsMu);
            if (m_hWs) {
                WinHttpCloseHandle(m_hWs);
                m_hWs = nullptr;
            }
        }
        if (m_ping.joinable()) m_ping.join();
        CloseAllStreams();
        m_consoleHost.Stop();
    }

private:
    static const DWORD kRecvBuf = 256 * 1024;

    Config m_cfg;
    HINTERNET m_hSession = nullptr;
    HINTERNET m_hConnect = nullptr;
    HINTERNET m_hWs = nullptr;              // доступ под m_wsMu (Teardown из watcher)
    std::mutex m_wsMu;
    std::atomic<bool> m_stopped{false};
    std::thread m_ping;
    ULONGLONG m_connectedAt = 0;
    DWORD m_httpStatus = 0;
    bool m_lastFatalAuth = false;

    ConsoleHostProcess m_consoleHost;        // Ш6: процесс захвата консоли под SYSTEM
    std::mutex m_sendMu;                     // единый писатель WS (серилизует кадры стримов)
    std::mutex m_streamsMu;
    // Владение ctx — разделяемое (RDP-09): карта + захваты по значению в
    // reader/writer-потоках; удаление из карты не освобождает ctx под ними.
    std::map<unsigned long long, std::shared_ptr<StreamCtx>> m_streams;

    static DWORD QueryStatusCode(HINTERNET hRequest) {
        DWORD code = 0, size = sizeof(code);
        WinHttpQueryHeaders(hRequest, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
            WINHTTP_HEADER_NAME_BY_INDEX, &code, &size, WINHTTP_NO_HEADER_INDEX);
        return code;
    }

    bool WsSendRaw(WINHTTP_WEB_SOCKET_BUFFER_TYPE bufType, const void* p, DWORD n) {
        std::lock_guard<std::mutex> lk(m_sendMu);
        if (m_stopped.load()) return false;
        HINTERNET hWs = nullptr;
        {
            std::lock_guard<std::mutex> lk2(m_wsMu);
            hWs = m_hWs;
        }
        if (!hWs) return false;
        return WinHttpWebSocketSend(hWs, bufType, (PVOID)p, n) == NO_ERROR;
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
        } else if (type == "agent_console_wake") {
            // Ш5 (console-any-state): юзер вошёл, приложение закрыто —
            // поднять клиент в консольной сессии, ответить wake_result.
            HandleConsoleWake(json);
        } else if (type == "console_start") {
            // Ш6: ядро запрашивает старт headless-воркера консоли под SYSTEM
            std::string sessId = JsonExtractString(json, "session_id");
            std::string sUrl = JsonExtractString(json, "server_url");
            std::string token = JsonExtractString(json, "host_token");
            std::wstring wsUrl = Utf8ToWide(sUrl);
            Log(L"console_start: сессия %S, URL %s", sessId.c_str(), wsUrl.c_str());
            m_consoleHost.Start(sessId, wsUrl, token, [this, sessId](bool ok, const char* reason) {
                Log(L"console_start_result: сессия %S -> %d (%S)", sessId.c_str(), ok ? 1 : 0, reason ? reason : "");
                WsSendText("{\"type\":\"console_start_result\",\"session_id\":\"" + sessId +
                           "\",\"started\":" + (ok ? "true" : "false") +
                           ",\"reason\":\"" + std::string(reason ? reason : "") + "\"}");
            });
        } else if (type == "console_stop") {
            std::string sessId = JsonExtractString(json, "session_id");
            Log(L"console_stop: сессия %S", sessId.c_str());
            m_consoleHost.Stop(sessId);
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
        auto ctx = std::make_shared<StreamCtx>();
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
        // Reader/writer стрима (RDP-09): shared_ptr по значению — ctx живёт,
        // пока работает последний из потоков, независимо от карты стримов;
        // сессия — через shared_from_this: Teardown/деструктор не раньше
        // завершения всех захватов.
        std::thread([self = shared_from_this(), ctx] { self->StreamReader(ctx); }).detach();
        std::thread([self = shared_from_this(), ctx] { self->StreamWriter(ctx); }).detach();
    }

    // ---- Ш5: wake приложения в консольной сессии ----
    // Порядок проверок задаёт ЧЕСТНЫЙ код ошибки (план Ш5: «нет вошедшего
    // пользователя» ≠ «не удалось поднять»); ядро ждёт ответ ~10с — всё
    // локальное и быстрое, в отдельный поток не выносим (как HandleDial).
    void HandleConsoleWake(const std::string& json) {
        const std::string sessionId = JsonExtractString(json, "session_id");

        // 1) Уже запущен в любой сессии — доставляем session_id через локальный IPC (A-04)
        DWORD runningSession = 0xFFFFFFFF;
        if (FindRunningAppSession(runningSession)) {
            Log(L"agent_console_wake %S: клиент уже запущен в сессии %lu, доставляем через IPC",
                sessionId.c_str(), runningSession);
            if (DeliverAutoshareToRunningApp(sessionId)) {
                Log(L"agent_console_wake %S: намерение успешно доставлено работающему приложению",
                    sessionId.c_str());
                SendConsoleWakeResult(sessionId, true, "delivered");
                return;
            }
            Log(L"agent_console_wake %S: запущенное приложение в сессии %lu не ответило на IPC",
                sessionId.c_str(), runningSession);
            DWORD activeConsole = WTSGetActiveConsoleSessionId();
            if (runningSession == activeConsole) {
                // Приложение работает в текущей консоли, но не готово (на экране логина или зависло)
                SendConsoleWakeResult(sessionId, false, "app_unresponsive_or_not_logged_in");
                return;
            }
            // Если процесс в другой сессии, продолжаем попытку поднять в активной консольной сессии
        }

        // 2) Ищем токен пользователя: сначала в активной консольной сессии.
        DWORD targetSession = WTSGetActiveConsoleSessionId();
        HANDLE hToken = nullptr;
        if (targetSession != 0xFFFFFFFF) {
            WTSQueryUserToken(targetSession, &hToken);
        }

        // 3) Если в консольной сессии токена нет — перебираем остальные сессии (экран заблокирован / Fast User Switching).
        if (!hToken) {
            PWTS_SESSION_INFOW pSessions = nullptr;
            DWORD count = 0;
            if (WTSEnumerateSessionsW(WTS_CURRENT_SERVER_HANDLE, 0, 1, &pSessions, &count)) {
                for (int pass = 0; pass < 3 && hToken == nullptr; pass++) {
                    WTS_CONNECTSTATE_CLASS desiredState = (pass == 0) ? WTSActive : ((pass == 1) ? WTSConnected : WTSDisconnected);
                    for (DWORD i = 0; i < count; i++) {
                        if (pSessions[i].State == desiredState && pSessions[i].SessionId != targetSession) {
                            if (WTSQueryUserToken(pSessions[i].SessionId, &hToken)) {
                                targetSession = pSessions[i].SessionId;
                                break;
                            }
                        }
                    }
                }
                WTSFreeMemory(pSessions);
            }
        }

        // 4) Если пользователя нет вообще (экран входа Windows / до логона) —
        // дублируем SYSTEM токен службы в консольную сессию.
        if (!hToken) {
            DWORD console = (targetSession != 0xFFFFFFFF) ? targetSession : WTSGetActiveConsoleSessionId();
            if (console != 0xFFFFFFFF) {
                HANDLE hProcessToken = nullptr;
                if (OpenProcessToken(GetCurrentProcess(), TOKEN_DUPLICATE | TOKEN_ASSIGN_PRIMARY | TOKEN_QUERY | TOKEN_ADJUST_SESSIONID, &hProcessToken)) {
                    // SecurityImpersonation (НЕ SecurityIdentification):
                    // identification-токен по документации не годится для
                    // CreateProcessAsUserW — спавн приложения до логина падал
                    // как spawn_failed (wake не поднимал консоль).
                    if (DuplicateTokenEx(hProcessToken, MAXIMUM_ALLOWED, nullptr, SecurityImpersonation, TokenPrimary, &hToken)) {
                        if (SetTokenInformation(hToken, TokenSessionId, &console, sizeof(console))) {
                            targetSession = console;
                        } else {
                            CloseHandle(hToken);
                            hToken = nullptr;
                        }
                    }
                    CloseHandle(hProcessToken);
                }
            }
        }

        if (!hToken) {
            Log(L"agent_console_wake %S: не удалось получить токен для сессии %lu",
                sessionId.c_str(), targetSession);
            SendConsoleWakeResult(sessionId, false, "no_user_token");
            return;
        }

        // 5) Спавн с --autoshare=<session_id> (авто-логин приложения).
        const bool ok = SpawnAppInSession(hToken, targetSession, Utf8ToWide(sessionId));
        CloseHandle(hToken);
        SendConsoleWakeResult(sessionId, ok, ok ? "launched" : "spawn_failed");
    }

    void SendConsoleWakeResult(const std::string& sessionId, bool spawned, const char* reason) {
        // session_id — UUID, экранирование не требуется (как agent_key в Connect).
        WsSendText("{\"type\":\"agent_console_wake_result\",\"session_id\":\"" + sessionId +
                   "\",\"spawned\":" + (spawned ? "true" : "false") +
                   ",\"reason\":\"" + std::string(reason) + "\"}");
    }

    // ---- бинарные кадры ядра → очередь стрима (TCP отправляет writer) ----

    void HandleBinary(const std::string& frame) {
        if (frame.size() < 8) return; // мусорный кадр без заголовка stream_id
        unsigned long long sid = 0;
        for (int i = 0; i < 8; i++) sid = (sid << 8) | (unsigned char)frame[i];
        // RDP-09: локальная копия shared_ptr — после отпускания мьютекса ctx
        // не может быть освобождён/закрыт параллельным KillStream.
        std::shared_ptr<StreamCtx> ctx;
        {
            std::lock_guard<std::mutex> lk(m_streamsMu);
            auto it = m_streams.find(sid);
            if (it != m_streams.end()) ctx = it->second;
        }
        if (!ctx) {
            // Неизвестный стрим: гасим сторону ядра без нового TCP (план §6).
            WsSendText("{\"type\":\"agent_close\",\"stream_id\":" + std::to_string(sid) +
                       ",\"reason\":\"unknown_stream\"}");
            return;
        }
        if (ctx->dead.load()) return; // уже гасится — данные в никуда
        std::string payload(frame.data() + 8, frame.size() - 8);
        if (!ctx->Enqueue(std::move(payload))) {
            // RDP-14: перестоявшая очередь = мёртвый стрим, а не блокировка
            // контрольного канала.
            Log(L"стрим %llu: очередь ядро→TCP переполнена (%zu байт) — гашу стрим",
                sid, kStreamQueueMaxBytes);
            KillStream(sid);
            SendAgentClose(sid, "send_queue_overflow");
        }
    }

    // ---- стримы ----

    // Reader: TCP → бинарные кадры [8B id][данные].
    void StreamReader(std::shared_ptr<StreamCtx> ctx) {
        std::vector<char> buf(32 * 1024 + 8); // [8B id][данные] — как agentChunkSize ядра
        for (;;) {
            SOCKET s = ctx->SockSnapshot();
            if (s == INVALID_SOCKET || ctx->dead.load()) break;
            int n = recv(s, buf.data() + 8, 32 * 1024, 0);
            if (n <= 0) break;
            for (int i = 0; i < 8; i++) buf[i] = (char)((ctx->id >> (56 - 8 * i)) & 0xFF);
            if (!WsSendRaw(WINHTTP_WEB_SOCKET_BINARY_MESSAGE_BUFFER_TYPE, buf.data(), (DWORD)(n + 8))) {
                break; // туннель мёртв — TCP закроется CloseSocketOnce ниже
            }
        }
        if (!ctx->dead.load()) {
            SendAgentClose(ctx->id, "tcp_eof");
            KillStream(ctx->id);
        }
        // Единственное закрытие сокета (no-op, если уже закрыт KillStream'ом)
        // и вычистка из карты, если стрим ещё там.
        ctx->CloseSocketOnce();
        {
            std::lock_guard<std::mutex> lk(m_streamsMu);
            auto it = m_streams.find(ctx->id);
            if (it != m_streams.end() && it->second == ctx) m_streams.erase(it);
        }
    }

    // Writer (RDP-14): единственный, кто делает send() в TCP стрима —
    // Run-поток (контрольный канал) от очереди не блокируется.
    void StreamWriter(std::shared_ptr<StreamCtx> ctx) {
        for (;;) {
            std::string chunk;
            {
                std::unique_lock<std::mutex> lk(ctx->qMu);
                ctx->qCv.wait(lk, [&ctx] { return ctx->qAbort || !ctx->q.empty(); });
                if (ctx->qAbort) return;
                chunk = std::move(ctx->q.front());
                ctx->q.pop_front();
                ctx->queuedBytes -= chunk.size();
            }
            size_t off = 0;
            while (off < chunk.size()) {
                SOCKET s = ctx->SockSnapshot();
                if (s == INVALID_SOCKET || ctx->dead.load()) return; // стрим погашен
                int w = send(s, chunk.data() + off, (int)(chunk.size() - off), 0);
                if (w <= 0) {
                    Log(L"стрим %llu: TCP-запись сломалась (WSA %d) — гашу стрим",
                        ctx->id, WSAGetLastError());
                    SendAgentClose(ctx->id, "tcp_write_failed");
                    KillStream(ctx->id);
                    return;
                }
                off += (size_t)w;
            }
        }
    }

    void SendAgentClose(unsigned long long sid, const char* reason) {
        WsSendText("{\"type\":\"agent_close\",\"stream_id\":" + std::to_string(sid) +
                   ",\"reason\":\"" + std::string(reason) + "\"}");
    }

    // Закрыть стрим со стороны агента: пометить dead, ЕДИНОВРЕМЕННО закрыть
    // TCP (compare_exchange внутри) — reader/writer проснутся закрытым
    // сокетом и abort-флагом очереди и завершатся сами.
    void KillStream(unsigned long long sid) {
        std::shared_ptr<StreamCtx> ctx;
        {
            std::lock_guard<std::mutex> lk(m_streamsMu);
            auto it = m_streams.find(sid);
            if (it == m_streams.end()) return;
            ctx = it->second;
            m_streams.erase(it);
        }
        if (ctx) {
            ctx->dead.store(true);
            ctx->CloseSocketOnce();
        }
    }

    void CloseAllStreams() {
        std::vector<std::shared_ptr<StreamCtx>> list;
        {
            std::lock_guard<std::mutex> lk(m_streamsMu);
            for (auto& kv : m_streams) list.push_back(kv.second);
            m_streams.clear();
        }
        for (auto& ctx : list) {
            ctx->dead.store(true);
            ctx->CloseSocketOnce();
        }
        // reader/writer-потоки разбужены закрытым сокетом и abort'ом —
        // освободят свои shared_ptr-копии и завершат жизнь ctx.
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
