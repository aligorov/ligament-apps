// service.cpp — Ligament 2FA Service («Ligament2FAService»)
//
// Служебный агент-сторож (watchdog) клиентской части Ligament 2FA:
// на рабочих станциях с политикой AllowExit=0 (выход из приложения
// запрещён) служба гарантирует присутствие запущенного клиента
// ligament_authenticator.exe в каждой активной пользовательской сессии.
// Если процесс убит (краш/диспетчер задач) — перезапускает его в сессии
// пользователя (WTSQueryUserToken + CreateProcessAsUser, --minimized).
// При AllowExit=1 (выход разрешён) служба ничего не делает.
//
// Лог: C:\ProgramData\Ligament\service.log (DACL SYSTEM/Admins — как cp.log).
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <wtsapi32.h>
#include <tlhelp32.h>
#include <sddl.h>
#include <shlobj.h>
#include <stdio.h>
#include <stdarg.h>
#include <string>
#include <map>

#pragma comment(lib, "wtsapi32.lib")
#pragma comment(lib, "advapi32.lib")
#pragma comment(lib, "user32.lib")

namespace {

const wchar_t* kSvcName = L"Ligament2FAService";
const wchar_t* kAppExe = L"ligament_authenticator.exe";
const DWORD kCheckIntervalMs = 15000;
const DWORD kRelaunchCooldownMs = 60000; // не чаще раза в минуту на сессию

SERVICE_STATUS g_status = {};
SERVICE_STATUS_HANDLE g_hStatus = nullptr;
HANDLE g_hStop = nullptr;

// ---------- Лог: ProgramData\Ligament\service.log ----------
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
        wcscat_s(progData, L"\\service.log");
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

// ---------- Конфиг: AllowExit (Policies → локальный ключ) ----------
// Семантика как в GPOService приложения: нет значения = выход разрешён.
bool PolicyAllowExit() {
    const wchar_t* keys[2] = {
        L"SOFTWARE\\Policies\\Ligament\\2FA",
        L"SOFTWARE\\Ligament\\2FA",
    };
    for (auto keyPath : keys) {
        HKEY hKey = nullptr;
        if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, keyPath, 0, KEY_READ | KEY_WOW64_64KEY, &hKey) == ERROR_SUCCESS) {
            DWORD val = 0, type = 0, size = sizeof(val);
            if (RegQueryValueExW(hKey, L"AllowExit", nullptr, &type, (LPBYTE)&val, &size) == ERROR_SUCCESS &&
                type == REG_DWORD) {
                RegCloseKey(hKey);
                return val != 0;
            }
            RegCloseKey(hKey);
        }
    }
    return true;
}

// ---------- Есть ли живой процесс приложения в сессии ----------
bool AppRunningInSession(DWORD sessionId) {
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == INVALID_HANDLE_VALUE) return true; // не знаем — не перезапускаем
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

// ---------- Запуск приложения в пользовательской сессии ----------
bool LaunchAppInSession(DWORD sessionId) {
    HANDLE hToken = nullptr;
    if (!WTSQueryUserToken(sessionId, &hToken)) {
        Log(L"запуск в сессии %lu: WTSQueryUserToken failed %lu", sessionId, GetLastError());
        return false;
    }

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
    wchar_t args[MAX_PATH + 32] = {0};
    swprintf_s(args, L"\"%s\" --minimized", appPath);
    PROCESS_INFORMATION pi = {};
    BOOL ok = CreateProcessAsUserW(hToken, appPath, args, nullptr, nullptr,
        FALSE, 0, nullptr, nullptr, &si, &pi);
    if (ok) {
        Log(L"клиент перезапущен в сессии %lu (pid %lu)", sessionId, pi.dwProcessId);
        CloseHandle(pi.hThread);
        CloseHandle(pi.hProcess);
    } else {
        Log(L"запуск в сессии %lu: CreateProcessAsUserW failed %lu", sessionId, GetLastError());
    }
    CloseHandle(hToken);
    return ok != FALSE;
}

// ---------- Рабочий цикл ----------
void WorkerLoop() {
    std::map<DWORD, ULONGLONG> lastLaunch; // sessionId -> GetTickCount64
    while (WaitForSingleObject(g_hStop, kCheckIntervalMs) == WAIT_TIMEOUT) {
        if (PolicyAllowExit()) continue; // выход разрешён — не навязываем

        PWTS_SESSION_INFOW sessions = nullptr;
        DWORD count = 0;
        if (!WTSEnumerateSessionsW(WTS_CURRENT_SERVER_HANDLE, 0, 1, &sessions, &count)) continue;

        for (DWORD i = 0; i < count; ++i) {
            if (sessions[i].State != WTSActive) continue;
            DWORD sid = sessions[i].SessionId;
            if (sid == 0) continue; // сессия services
            if (AppRunningInSession(sid)) continue;

            ULONGLONG now = GetTickCount64();
            ULONGLONG& last = lastLaunch[sid];
            if (last != 0 && now - last < kRelaunchCooldownMs) continue; // анти-цикл при краше
            last = now;
            Log(L"клиент отсутствует в активной сессии %lu — перезапуск", sid);
            LaunchAppInSession(sid);
        }
        WTSFreeMemory(sessions);
    }
}

// ---------- SCM ----------
void WINAPI SvcHandler(DWORD control) {
    switch (control) {
    case SERVICE_CONTROL_STOP:
    case SERVICE_CONTROL_SHUTDOWN:
        g_status.dwCurrentState = SERVICE_STOP_PENDING;
        g_status.dwWaitHint = 5000;
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
    Log(L"служба запущена (pid=%lu)", GetCurrentProcessId());

    WorkerLoop();

    g_status.dwCurrentState = SERVICE_STOPPED;
    SetServiceStatus(g_hStatus, &g_status);
    Log(L"служба остановлена");
    if (g_hStop) CloseHandle(g_hStop);
}

} // namespace

int wmain(int argc, wchar_t** argv) {
    if (argc > 1 && wcscmp(argv[1], L"--console") == 0) {
        // отладка: g_hStop не создаётся, WorkerLoop с WaitForSingleObject(nullptr)
        // вернёт WAIT_FAILED — вместо этого простой прогон конфигурации.
        printf("AllowExit=%d\n", PolicyAllowExit() ? 1 : 0);
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
