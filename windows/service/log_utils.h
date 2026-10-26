#pragma once

#include <windows.h>
#include <stdio.h>
#include <string>

inline void FormatLogTimestamp(wchar_t* out, size_t count) {
    SYSTEMTIME st;
    GetLocalTime(&st);
    TIME_ZONE_INFORMATION tzi = {};
    const DWORD zone = GetTimeZoneInformation(&tzi);
    LONG bias = tzi.Bias;
    if (zone == TIME_ZONE_ID_DAYLIGHT) bias += tzi.DaylightBias;
    const LONG offset = -bias;
    const LONG absolute = offset >= 0 ? offset : -offset;
    swprintf_s(out, count, L"%04u-%02u-%02uT%02u:%02u:%02u%c%02d:%02d",
        st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond,
        offset >= 0 ? L'+' : L'-', absolute / 60, absolute % 60);
}

inline bool WriteLogBom(HANDLE file) {
    const unsigned char bom[] = {0xEF, 0xBB, 0xBF};
    DWORD written = 0;
    return WriteFile(file, bom, sizeof(bom), &written, nullptr) && written == sizeof(bom);
}

inline void AppendUtf8LogLine(const wchar_t* path, const wchar_t* line) {
    HANDLE file = CreateFileW(path, FILE_APPEND_DATA | GENERIC_READ,
        FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS,
        FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
    if (file == INVALID_HANDLE_VALUE) return;

    LARGE_INTEGER size = {};
    if (!GetFileSizeEx(file, &size)) {
        CloseHandle(file);
        return;
    }
    if (size.QuadPart == 0) {
        if (!WriteLogBom(file)) {
            CloseHandle(file);
            return;
        }
    } else {
        unsigned char bom[3] = {};
        DWORD read = 0;
        SetFilePointer(file, 0, nullptr, FILE_BEGIN);
        if (!ReadFile(file, bom, sizeof(bom), &read, nullptr)) {
            CloseHandle(file);
            return;
        }
        if (read != sizeof(bom) || bom[0] != 0xEF || bom[1] != 0xBB || bom[2] != 0xBF) {
            CloseHandle(file);
            wchar_t legacy[MAX_PATH];
            swprintf_s(legacy, L"%s.%lu.%lu.legacy", path,
                GetCurrentProcessId(), GetTickCount());
            if (!MoveFileExW(path, legacy, MOVEFILE_WRITE_THROUGH)) return;
            file = CreateFileW(path, FILE_APPEND_DATA | GENERIC_READ,
                FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS,
                FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
            if (file == INVALID_HANDLE_VALUE) return;
            if (!WriteLogBom(file)) {
                CloseHandle(file);
                return;
            }
        }
    }

    const int required = WideCharToMultiByte(CP_UTF8, 0, line, -1, nullptr, 0, nullptr, nullptr);
    if (required > 1) {
        std::string utf8(required - 1, '\0');
        WideCharToMultiByte(CP_UTF8, 0, line, -1, utf8.data(), required, nullptr, nullptr);
        SetFilePointer(file, 0, nullptr, FILE_END);
        DWORD written = 0;
        WriteFile(file, utf8.data(), static_cast<DWORD>(utf8.size()), &written, nullptr);
    }
    CloseHandle(file);
}
