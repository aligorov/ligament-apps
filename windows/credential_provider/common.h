// common.h — Common definitions, logging, and configuration for Ligament 2FA Credential Provider
#pragma once

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif

#include <winsock2.h>
#include <ws2tcpip.h>
#include <iphlpapi.h>
#include <windows.h>
#include <objbase.h> // CoInitializeEx/CoUninitialize (воркер: SetField*/CredentialsChanged)
#include <credentialprovider.h>
#include <ntsecapi.h>
#include <winhttp.h>
#include <webauthn.h>
#include <shlwapi.h>
#include <wtsapi32.h>
#include <shlobj.h>   // SHGetFolderPathW (CPLog → %ProgramData%\Ligament)
#include <stdarg.h>   // va_list (CPLog)
#include <stdio.h>    // swprintf_s/_vsnwprintf_s (CPLog)
#include <sddl.h>     // ConvertStringSecurityDescriptorToSecurityDescriptorW (DACL cp.log)
#include <aclapi.h>   // SetNamedSecurityInfoW (перехват владения cp.log/каталогом)

#include <string>
#include <vector>
#include <memory>
#include <sstream>

#include "guid.h"

#pragma comment(lib, "winhttp.lib")
#pragma comment(lib, "secur32.lib")
#pragma comment(lib, "credui.lib")
#pragma comment(lib, "shlwapi.lib")
#pragma comment(lib, "wtsapi32.lib")
#pragma comment(lib, "ws2_32.lib")
#pragma comment(lib, "iphlpapi.lib")
#pragma comment(lib, "advapi32.lib")

namespace ligament {

extern LONG g_cRefDll;

// Configuration loaded from registry (GPO: HKLM\SOFTWARE\Policies\Ligament\2FA)
struct Config {
    // Пустая = сервер не настроен: провайдер НЕ применяет 2FA ни к RDP, ни
    // к консоли (см. LigamentProvider::SetUsageScenario / Filter) и не
    // подавляет штатный парольный тайл. Фантомного дефолта вида
    // https://twofa.corp.local больше нет — он блокировал входы на
    // несконфигурированных машинах при FailClose=1.
    std::wstring serverUrl;
    bool serverUrlConfigured = false; // ServerURL реально задан в реестре (GPO/MSI)
    std::wstring fallbackRelayUrl; // Relay fallback URL — ТОЛЬКО https (напр. "https://relay-branch.corp:8443"): по relay уходят доменные креды
    bool rdp2faEnabled = true;
    bool console2faEnabled = false;
    bool fido2Enabled = true;
    int defaultFactor = 0; // 0 = Push (приложение Ligament / Telegram), 1 = Passkey (QR-код), 2 = OTP (TOTP)
    int pushTimeoutSec = 45;
    bool failClose = true;
    bool allowSelfSigned = false;
    // Диагностическая SAM-проба (LogonUser) после неудачного входа.
    // ВЫКЛЮЧЕНА по умолчанию: каждая неудачная проба += 1 к badPwdCount,
    // до 3 проб на вход ускоряют AD-lockout учётки в 4 раза.
    bool samProbeEnabled = false;
    std::vector<std::wstring> bypassAccounts;

    static Config LoadFromRegistry() {
        Config cfg;

        HKEY hKeyPolicy = nullptr;
        RegOpenKeyExW(HKEY_LOCAL_MACHINE, L"SOFTWARE\\Policies\\Ligament\\2FA", 0, KEY_READ | KEY_WOW64_64KEY, &hKeyPolicy);

        HKEY hKeyLocal = nullptr;
        RegOpenKeyExW(HKEY_LOCAL_MACHINE, L"SOFTWARE\\Ligament\\2FA", 0, KEY_READ | KEY_WOW64_64KEY, &hKeyLocal);

        auto readString = [&](const wchar_t* name, std::wstring& outVal) -> bool {
            wchar_t buf[2048] = {0};
            DWORD dwType = 0, dwSize = sizeof(buf);
            // 1. Check GPO policy first
            if (hKeyPolicy && RegQueryValueExW(hKeyPolicy, name, nullptr, &dwType, (LPBYTE)buf, &dwSize) == ERROR_SUCCESS && (dwType == REG_SZ || dwType == REG_EXPAND_SZ)) {
                std::wstring s = buf;
                size_t first = s.find_first_not_of(L" \t\r\n");
                if (first != std::wstring::npos) {
                    size_t last = s.find_last_not_of(L" \t\r\n");
                    outVal = s.substr(first, last - first + 1);
                    return true;
                }
            }
            // 2. Fallback to Local machine settings
            dwSize = sizeof(buf);
            if (hKeyLocal && RegQueryValueExW(hKeyLocal, name, nullptr, &dwType, (LPBYTE)buf, &dwSize) == ERROR_SUCCESS && (dwType == REG_SZ || dwType == REG_EXPAND_SZ)) {
                std::wstring s = buf;
                size_t first = s.find_first_not_of(L" \t\r\n");
                if (first != std::wstring::npos) {
                    size_t last = s.find_last_not_of(L" \t\r\n");
                    outVal = s.substr(first, last - first + 1);
                    return true;
                }
            }
            return false;
        };

        auto readDword = [&](const wchar_t* name, bool& outVal) -> bool {
            DWORD dwVal = 0, dwType = 0, dwSize = sizeof(dwVal);
            if (hKeyPolicy && RegQueryValueExW(hKeyPolicy, name, nullptr, &dwType, (LPBYTE)&dwVal, &dwSize) == ERROR_SUCCESS && (dwType == REG_DWORD)) {
                outVal = (dwVal != 0);
                return true;
            }
            if (hKeyLocal && RegQueryValueExW(hKeyLocal, name, nullptr, &dwType, (LPBYTE)&dwVal, &dwSize) == ERROR_SUCCESS && (dwType == REG_DWORD)) {
                outVal = (dwVal != 0);
                return true;
            }
            return false;
        };

        auto readInt = [&](const wchar_t* name, int& outVal) -> bool {
            DWORD dwVal = 0, dwType = 0, dwSize = sizeof(dwVal);
            if (hKeyPolicy && RegQueryValueExW(hKeyPolicy, name, nullptr, &dwType, (LPBYTE)&dwVal, &dwSize) == ERROR_SUCCESS && (dwType == REG_DWORD)) {
                outVal = (int)dwVal;
                return true;
            }
            if (hKeyLocal && RegQueryValueExW(hKeyLocal, name, nullptr, &dwType, (LPBYTE)&dwVal, &dwSize) == ERROR_SUCCESS && (dwType == REG_DWORD)) {
                outVal = (int)dwVal;
                return true;
            }
            return false;
        };

        // ServerURL должен быть задан явно (GPO / MSI / install-latest.ps1).
        // Пустое или отсутствующее значение = «2FA не настроена»: провайдер
        // полностью пассивен, входы идут через штатные тайлы Windows.
        cfg.serverUrlConfigured = readString(L"ServerURL", cfg.serverUrl);
        if (!cfg.serverUrlConfigured) {
            cfg.serverUrl.clear();
        }
        readString(L"FallbackRelayURL", cfg.fallbackRelayUrl);
        readDword(L"RDP2FAEnabled", cfg.rdp2faEnabled);
        readDword(L"Console2FAEnabled", cfg.console2faEnabled);
        readDword(L"FIDO2Enabled", cfg.fido2Enabled);
        readInt(L"DefaultFactor", cfg.defaultFactor);
        readInt(L"PushTimeoutSeconds", cfg.pushTimeoutSec);
        readDword(L"FailClose", cfg.failClose);
        readDword(L"AllowSelfSigned", cfg.allowSelfSigned);
        readDword(L"SamProbeEnabled", cfg.samProbeEnabled);

        std::wstring bypassRaw;
        if (readString(L"BypassAccounts", bypassRaw)) {
            cfg.bypassAccounts.clear();
            for (auto& ch : bypassRaw) {
                if (ch == L';' || ch == L'|') ch = L',';
            }
            std::wstringstream ss(bypassRaw);
            std::wstring item;
            while (std::getline(ss, item, L',')) {
                size_t first = item.find_first_not_of(L" \t\r\n");
                if (first != std::wstring::npos) {
                    size_t last = item.find_last_not_of(L" \t\r\n");
                    cfg.bypassAccounts.push_back(item.substr(first, (last - first + 1)));
                }
            }
        }

        if (hKeyPolicy) RegCloseKey(hKeyPolicy);
        if (hKeyLocal) RegCloseKey(hKeyLocal);

        return cfg;
    }

    bool IsBypassAccount(const std::wstring& username, const std::wstring& domain = L"") const {
        if (username.empty() || bypassAccounts.empty()) return false;

        // Clean user: extract pure username (without domain/UPN/slashes)
        std::wstring rawUser = username;
        bool hadDomain = false;
        size_t slash = rawUser.find_last_of(L"\\/");
        if (slash != std::wstring::npos && slash + 1 < rawUser.length()) {
            rawUser = rawUser.substr(slash + 1);
            hadDomain = true;
        }
        size_t at = rawUser.find(L'@');
        if (at != std::wstring::npos) {
            rawUser = rawUser.substr(0, at);
            hadDomain = true;
        }

        // Короткое имя из списка матчится ТОЛЬКО когда пользователь ввёл
        // имя без домена. Раньше «administrator» из BypassAccounts отключал
        // 2FA для ЛЮБОГО «какой-то-домен\administrator»; теперь доменное
        // имя требует домен и в записи списка (DOMAIN\user / user@domain).
        for (const auto& acc : bypassAccounts) {
            if (_wcsicmp(acc.c_str(), username.c_str()) == 0) return true;
            if (!hadDomain && _wcsicmp(acc.c_str(), rawUser.c_str()) == 0) return true;

            if (!domain.empty()) {
                std::wstring fullNetbios = domain + L"\\" + rawUser;
                std::wstring fullUpn = rawUser + L"@" + domain;
                if (_wcsicmp(acc.c_str(), fullNetbios.c_str()) == 0) return true;
                if (_wcsicmp(acc.c_str(), fullUpn.c_str()) == 0) return true;
            }
        }
        return false;
    }
};

// Файловое приложение к cp.log (тот же формат, что CPLog в LigamentCredential).
// Winlogon/LogonUI-контекст: отладчика нет, файл — единственное «окно».
//
// Безопасность файла (cp.log пишет SYSTEM, читает никто):
//  - каталог и файл создаются с ЯВНЫМ DACL «SYSTEM+Administrators full»
//    (D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)), унаследованные ACE блокируются —
//    дефолтный ProgramData-ACL оставил бы файл доступным стандартному
//    пользователю (лог содержит имена пользователей и IP);
//  - если каталог ProgramData\Ligament уже существовал (pre-create атака),
//    владение и DACL принудительно переписываются от SYSTEM; не вышло —
//    файловое логирование отключается (в чужой каталог не пишем);
//  - файл открывается с FILE_FLAG_OPEN_REPARSE_POINT: подмененный cp.log
//    (symlink/hardlink) не приводит к записи от SYSTEM в цель ссылки.
inline void LogCPFileLine(const wchar_t* line) {
    static wchar_t s_path[MAX_PATH] = {0};
    static bool s_disabled = false;
    static SECURITY_ATTRIBUTES s_sa = {sizeof(SECURITY_ATTRIBUTES), nullptr, FALSE};
    static bool s_saInit = false;

    if (s_disabled) return;

    if (!s_saInit) {
        s_saInit = true;
        if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
                L"D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)",
                SDDL_REVISION_1, &s_sa.lpSecurityDescriptor, nullptr)) {
            s_sa.lpSecurityDescriptor = nullptr;
        }
    }

    // Переписать владельца и DACL объекта от SYSTEM. Нужно ровно один раз
    // на каталог и файл; повторные вызовы дешёвые (no-op при совпадении).
    auto enforceSystemAcl = [](const wchar_t* objectPath) -> bool {
        if (!s_sa.lpSecurityDescriptor) return false;
        PACL dacl = nullptr;
        BOOL present = FALSE, defaulted = FALSE;
        if (!GetSecurityDescriptorDacl(s_sa.lpSecurityDescriptor, &present, &dacl, &defaulted) || !present) {
            return false;
        }
        SID_IDENTIFIER_AUTHORITY ntAuth = SECURITY_NT_AUTHORITY;
        PSID sidSystem = nullptr;
        if (!AllocateAndInitializeSid(&ntAuth, 1, SECURITY_LOCAL_SYSTEM_RID,
                0, 0, 0, 0, 0, 0, 0, &sidSystem)) {
            return false;
        }
        DWORD rc = SetNamedSecurityInfoW(const_cast<LPWSTR>(objectPath), SE_FILE_OBJECT,
            PROTECTED_DACL_SECURITY_INFORMATION | OWNER_SECURITY_INFORMATION,
            sidSystem, nullptr, dacl, nullptr);
        FreeSid(sidSystem);
        return rc == ERROR_SUCCESS;
    };

    if (s_path[0] == 0) {
        wchar_t progData[MAX_PATH] = {0};
        if (FAILED(SHGetFolderPathW(nullptr, CSIDL_COMMON_APPDATA, nullptr, 0, progData))) {
            s_disabled = true;
            return;
        }
        wcscat_s(progData, L"\\Ligament");
        CreateDirectoryW(progData, s_sa.lpSecurityDescriptor ? &s_sa : nullptr);
        if (!enforceSystemAcl(progData)) {
            s_disabled = true; // каталог не наш — не пишем
            return;
        }
        wcscat_s(progData, L"\\cp.log");
        wcscpy_s(s_path, progData);
    }

    // Подменённый cp.log (symlink на чужой файл) не трогаем вовсе: ни пишем,
    // ни переписываем ACL цели ссылки.
    DWORD attrs = GetFileAttributesW(s_path);
    if (attrs != INVALID_FILE_ATTRIBUTES && (attrs & FILE_ATTRIBUTE_REPARSE_POINT)) {
        s_disabled = true;
        return;
    }

    HANDLE h = CreateFileW(s_path, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE,
        s_sa.lpSecurityDescriptor ? &s_sa : nullptr, OPEN_ALWAYS,
        FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
    if (h == INVALID_HANDLE_VALUE) return;
    enforceSystemAcl(s_path); // существующий файл мог остаться со старым ACL
    SetFilePointer(h, 0, nullptr, FILE_END);
    DWORD written = 0;
    WriteFile(h, line, (DWORD)(wcslen(line) * sizeof(wchar_t)), &written, nullptr);
    CloseHandle(h);
}

// Logging helper: DebugView + файл cp.log (с таймстемпом, как CPLog).
inline void LogDebug(const wchar_t* fmt, ...) {
    wchar_t buf[1024];
    va_list args;
    va_start(args, fmt);
    _vsnwprintf_s(buf, _countof(buf), _TRUNCATE, fmt, args);
    va_end(args);
    OutputDebugStringW(L"[Ligament2FA] ");
    OutputDebugStringW(buf);
    OutputDebugStringW(L"\n");
    SYSTEMTIME st;
    GetLocalTime(&st);
    wchar_t line[1200];
    swprintf_s(line, L"[%02d.%02d %02d:%02d:%02d.%03d tid=%lu] %s\r\n",
        st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond, st.wMilliseconds,
        (unsigned long)GetCurrentThreadId(), buf);
    LogCPFileLine(line);
}

// UTF-8 <-> UTF-16 helpers
inline std::string WideToUtf8(const std::wstring& wstr) {
    if (wstr.empty()) return std::string();
    int sizeNeeded = WideCharToMultiByte(CP_UTF8, 0, wstr.data(), (int)wstr.size(), nullptr, 0, nullptr, nullptr);
    std::string result(sizeNeeded, 0);
    WideCharToMultiByte(CP_UTF8, 0, wstr.data(), (int)wstr.size(), &result[0], sizeNeeded, nullptr, nullptr);
    return result;
}

inline std::wstring Utf8ToWide(const std::string& str) {
    if (str.empty()) return std::wstring();
    int sizeNeeded = MultiByteToWideChar(CP_UTF8, 0, str.data(), (int)str.size(), nullptr, 0);
    std::wstring result(sizeNeeded, 0);
    MultiByteToWideChar(CP_UTF8, 0, str.data(), (int)str.size(), &result[0], sizeNeeded);
    return result;
}

// Escapes a UTF-8 string for embedding inside a JSON string literal:
// '"' and '\' are backslash-escaped, control characters < 0x20 become
// \u00XX. Prevents both malformed requests (passwords with quotes) and
// field injection via concatenated key duplication.
inline std::string EscapeJson(const std::string& str) {
    static const char hex[] = "0123456789abcdef";
    std::string out;
    out.reserve(str.size());
    for (char c : str) {
        switch (c) {
        case '"':  out += "\\\""; break;
        case '\\': out += "\\\\"; break;
        case '\b': out += "\\b"; break;
        case '\f': out += "\\f"; break;
        case '\n': out += "\\n"; break;
        case '\r': out += "\\r"; break;
        case '\t': out += "\\t"; break;
        default:
            if ((unsigned char)c < 0x20) {
                out += "\\u00";
                out += hex[(unsigned char)c >> 4];
                out += hex[(unsigned char)c & 0x0F];
            } else {
                out += c;
            }
            break;
        }
    }
    return out;
}

// Base64URL encoding/decoding for WebAuthn tokens
inline std::string Base64UrlEncode(const unsigned char* data, size_t len) {
    static const char lookup[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    std::string out;
    int val = 0, valb = -6;
    for (size_t i = 0; i < len; i++) {
        val = (val << 8) + data[i];
        valb += 8;
        while (valb >= 0) {
            out.push_back(lookup[(val >> valb) & 0x3F]);
            valb -= 6;
        }
    }
    if (valb > -6) out.push_back(lookup[((val << 8) >> (valb + 8)) & 0x3F]);
    return out;
}

inline std::string Base64UrlEncode(const std::string& str) {
    return Base64UrlEncode(reinterpret_cast<const unsigned char*>(str.data()), str.size());
}

inline std::string Base64UrlEncode(const std::vector<unsigned char>& vec) {
    return Base64UrlEncode(vec.data(), vec.size());
}

inline std::vector<unsigned char> Base64UrlDecode(const std::string& in) {
    std::vector<unsigned char> out;
    std::vector<int> T(256, -1);
    for (int i = 0; i < 64; i++) {
        T["ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"[i]] = i;
    }
    int val = 0, valb = -8;
    for (unsigned char c : in) {
        if (T[c] == -1) break;
        val = (val << 6) + T[c];
        valb += 6;
        if (valb >= 0) {
            out.push_back((val >> valb) & 0xFF);
            valb -= 8;
        }
    }
    return out;
}

inline std::string ExtractJsonString(const std::string& json, const std::string& key) {
    std::string needle = "\"" + key + "\"";
    size_t pos = json.find(needle);
    if (pos == std::string::npos) return "";

    pos = json.find(':', pos + needle.length());
    if (pos == std::string::npos) return "";

    pos = json.find('\"', pos + 1);
    if (pos == std::string::npos) return "";

    size_t end = json.find('\"', pos + 1);
    if (end == std::string::npos) return "";

    return json.substr(pos + 1, end - pos - 1);
}

inline bool ExtractJsonBool(const std::string& json, const std::string& key) {
    std::string needle = "\"" + key + "\"";
    size_t pos = json.find(needle);
    if (pos == std::string::npos) return false;

    pos = json.find(':', pos + needle.length());
    if (pos == std::string::npos) return false;

    size_t truePos = json.find("true", pos);
    size_t falsePos = json.find("false", pos);
    size_t commaPos = json.find_first_of(",}\n", pos);

    if (truePos != std::string::npos && (commaPos == std::string::npos || truePos < commaPos)) {
        return true;
    }
    return false;
}

// Числовой поле-экстрактор для ответов вида {"error":"rate_limited",
// "retry_after":30}: ExtractJsonString не видит значения без кавычек.
// Возвращает fallback, если ключа или числа нет.
inline int ExtractJsonInt(const std::string& json, const std::string& key, int fallback = 0) {
    std::string needle = "\"" + key + "\"";
    size_t pos = json.find(needle);
    if (pos == std::string::npos) return fallback;

    pos = json.find(':', pos + needle.length());
    if (pos == std::string::npos) return fallback;

    ++pos;
    while (pos < json.size() && (json[pos] == ' ' || json[pos] == '\t')) ++pos;
    size_t end = pos;
    while (end < json.size() && json[end] >= '0' && json[end] <= '9') ++end;
    if (end == pos) return fallback;
    return atoi(json.substr(pos, end - pos).c_str());
}

} // namespace ligament
