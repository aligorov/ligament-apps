// Windows-реализация чтения sso-билета (фаза 2).
//
// Путь: <ProgramData>\Ligament\sso\<SID текущего пользователя>\sso.bin.
// SID — из токена процесса (OpenProcessToken → GetTokenInformation(TokenUser)
// → ConvertSidToStringSidW), ProgramData — SHGetFolderPathW. Только Win32 FFI,
// никаких Platform.environment: env подменяется тривиально.
//
// Каждая ошибка = null (нет билета), исключения наружу не выходят: сбой
// identity-цепочки не должен беспокоить пользователя.
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

import 'sso_ticket.dart';

SsoTicketReader createSsoTicketReader() => WindowsSsoTicketReader();

class WindowsSsoTicketReader implements SsoTicketReader {
  @override
  Future<SsoTicket?> readTicket() async {
    if (!Platform.isWindows) return null;
    try {
      final sid = _currentProcessUserSid();
      if (sid == null || sid.isEmpty) return null;
      final programData = _commonAppDataPath();
      if (programData == null || programData.isEmpty) return null;

      final path = buildSsoTicketPath(programData, sid);
      final file = File(path);
      if (!await file.exists()) return null;
      final stat = await file.length();
      // Билет — короткая JWT-подобная строка; аномально большой файл
      // трактуем как «нет билета» (защита от мусора в ProgramData).
      if (stat <= 0 || stat > 64 * 1024) return null;
      final ticket = (await file.readAsString(encoding: utf8)).trim();
      if (ticket.isEmpty) return null;
      return SsoTicket(ticket);
    } catch (e) {
      // Нет доступа (чужая DACL), файл занят, битая кодировка — тихо.
      debugPrint('sso_ticket: чтение билета недоступно: $e');
      return null;
    }
  }

  /// SID пользователя текущего процесса в S-формате (S-1-5-21-...).
  static String? _currentProcessUserSid() {
    ffi.Pointer<ffi.Void>? token;
    ffi.Pointer<ffi.Uint8>? infoBuf;
    try {
      final advapi32 = ffi.DynamicLibrary.open('advapi32.dll');
      final kernel32 = ffi.DynamicLibrary.open('kernel32.dll');

      final getCurrentProcess = kernel32.lookupFunction<
          ffi.IntPtr Function(), int Function()>('GetCurrentProcess');
      final openProcessToken = advapi32.lookupFunction<
          ffi.Int32 Function(ffi.IntPtr, ffi.Uint32, ffi.Pointer<ffi.IntPtr>),
          int Function(int, int, ffi.Pointer<ffi.IntPtr>)>('OpenProcessToken');
      final getTokenInformation = advapi32.lookupFunction<
          ffi.Int32 Function(
              ffi.IntPtr,
              ffi.Int32,
              ffi.Pointer<ffi.Void>,
              ffi.Uint32,
              ffi.Pointer<ffi.Uint32>),
          int Function(int, int, ffi.Pointer<ffi.Void>, int,
              ffi.Pointer<ffi.Uint32>)>('GetTokenInformation');
      final convertSidToStringSidW = advapi32.lookupFunction<
          ffi.Int32 Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Pointer<ffi.Uint16>>),
          int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Pointer<ffi.Uint16>>)>(
          'ConvertSidToStringSidW');
      final localFree = kernel32.lookupFunction<
          ffi.IntPtr Function(ffi.IntPtr), int Function(int)>('LocalFree');

      const tokenQuery = 0x0008; // TOKEN_QUERY
      const tokenUserClass = 1; // TokenInformationClass::TokenUser

      final tokenOut = calloc<ffi.IntPtr>();
      if (openProcessToken(getCurrentProcess(), tokenQuery, tokenOut) == 0) {
        return null;
      }
      token = ffi.Pointer.fromAddress(tokenOut.value);
      calloc.free(tokenOut);

      // Первый вызов — узнать размер буфера TOKEN_USER.
      final needed = calloc<ffi.Uint32>();
      getTokenInformation(token.address, tokenUserClass, ffi.nullptr, 0, needed);
      final size = needed.value;
      if (size == 0) {
        calloc.free(needed);
        return null;
      }

      // TOKEN_USER: { PSID Sid; DWORD Attributes } — SID-указатель в начале.
      final user = calloc<ffi.Uint8>(size);
      infoBuf = user;
      if (getTokenInformation(token.address, tokenUserClass,
              user.cast<ffi.Void>(), size, needed) ==
          0) {
        calloc.free(needed);
        return null;
      }
      calloc.free(needed);

      final sidPtr = ffi.Pointer<ffi.Void>.fromAddress(
          user.cast<ffi.IntPtr>().value);

      final sidOut = calloc<ffi.Pointer<ffi.Uint16>>();
      if (convertSidToStringSidW(sidPtr, sidOut) == 0) {
        return null;
      }
      final sidStr = sidOut.value.cast<Utf16>().toDartString();
      localFree(sidOut.value.address);
      calloc.free(sidOut);
      return sidStr;
    } catch (e) {
      debugPrint('sso_ticket: SID недоступен: $e');
      return null;
    } finally {
      if (infoBuf != null) {
        calloc.free(infoBuf);
      }
      if (token != null) {
        try {
          final kernel32 = ffi.DynamicLibrary.open('kernel32.dll');
          final closeHandle = kernel32.lookupFunction<
              ffi.Int32 Function(ffi.IntPtr), int Function(int)>('CloseHandle');
          closeHandle(token.address);
        } catch (_) {}
      }
    }
  }

  /// C:\ProgramData через SHGetFolderPathW (CSIDL_COMMON_APPDATA).
  static String? _commonAppDataPath() {
    try {
      final shell32 = ffi.DynamicLibrary.open('shell32.dll');
      final getFolderPath = shell32.lookupFunction<
          ffi.Int32 Function(ffi.IntPtr, ffi.Int32, ffi.IntPtr, ffi.Uint32,
              ffi.Pointer<ffi.Uint16>),
          int Function(int, int, int, int, ffi.Pointer<ffi.Uint16>)>(
          'SHGetFolderPathW');
      const csidlCommonAppData = 0x0023;
      final buf = calloc<ffi.Uint16>(261); // MAX_PATH + 1
      final hr = getFolderPath(0, csidlCommonAppData, 0, 0, buf);
      if (hr != 0) {
        calloc.free(buf);
        return null;
      }
      final path = buf.cast<Utf16>().toDartString();
      calloc.free(buf);
      return path;
    } catch (e) {
      debugPrint('sso_ticket: ProgramData недоступен: $e');
      return null;
    }
  }
}
