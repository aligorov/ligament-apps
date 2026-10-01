import 'dart:ffi' as ffi;
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

// Буферы Win32: UNLEN = 256, DNLEN = 32767 (NameSamCompatible до 256*2)
final class _UserNameBuffer extends ffi.Struct {
  @ffi.Array.multi([256])
  external ffi.Array<ffi.Uint16> data;
}

typedef GetUserNameWNative = ffi.Int32 Function(
    ffi.Pointer<ffi.Uint16>, ffi.Pointer<ffi.Uint32>);
typedef GetUserNameWDart = int Function(
    ffi.Pointer<ffi.Uint16>, ffi.Pointer<ffi.Uint32>);

typedef GetComputerNameExWName = ffi.Int32 Function(ffi.Int32,
    ffi.Pointer<ffi.Uint16>, ffi.Pointer<ffi.Uint32>);
typedef GetComputerNameExWDart = int Function(
    int, ffi.Pointer<ffi.Uint16>, ffi.Pointer<ffi.Uint32>);

// NameFormat (secext.h): NameSamCompatible = 2
const int _nameSamCompatible = 2;
const int _computerNameDnsFullyQualified = 3;
const int _computerNameNetBios = 0;

/// Истинная идентичность текущей Windows-сессии.
///
/// Источник — Win32 API (advapi32!GetUserNameW, secext!GetUserNameExW,
/// kernel32!GetComputerNameExW), а НЕ переменные окружения: USERNAME
/// подменяется тривиально, API возвращает учётку, под которой выполняется
/// процесс. Подмена = запуск процесса под чужой учёткой, т.е. владение её
/// кредами — это и есть граница гарантии (см. docs/windows-sso-analysis.md).
class WindowsIdentity {
  WindowsIdentity._({
    required this.userName,
    this.domainName,
    required this.computerName,
  });

  /// Чистое имя пользователя без домена (ivanov)
  final String userName;

  /// NetBIOS/DNS-домен (CORP / corp.local), null для локальных учёток
  final String? domainName;

  /// Имя машины (DNS FQDN, фолбэк NetBIOS)
  final String computerName;

  /// Полное имя вида CORP\ivanov (для аудита/телеметрии)
  String get samCompatibleName =>
      (domainName == null || domainName!.isEmpty) ? userName : '$domainName\\$userName';

  bool get isDomainUser => domainName != null && domainName!.isNotEmpty;

  /// Сравнение с аккаунтом приложения (без домена, case-insensitive):
  /// true/false; null — платформа не Windows или identity недоступна.
  static bool? matchesAccount(String? accountUsername) {
    final ident = instance.collect();
    if (ident == null) return null;
    if (accountUsername == null || accountUsername.isEmpty) return null;
    final account = accountUsername.split('\\').last.split('@').first.toLowerCase();
    return ident.userName.toLowerCase() == account;
  }

  static final WindowsIdentity instance = WindowsIdentity._internal();
  WindowsIdentity._internal()
      : userName = '',
        domainName = null,
        computerName = '';

  WindowsIdentity? _cached;

  /// Identity не меняется в течение жизни процесса — собираем один раз.
  WindowsIdentity? collect() {
    if (!Platform.isWindows) return null;
    if (_cached != null) return _cached;
    try {
      _cached = _collectNow();
    } catch (e) {
      debugPrint('windows_identity: ошибка сбора: $e');
    }
    return _cached;
  }

  WindowsIdentity? _collectNow() {
    final advapi32 = ffi.DynamicLibrary.open('advapi32.dll');
    final kernel32 = ffi.DynamicLibrary.open('kernel32.dll');
    final secur32 = ffi.DynamicLibrary.open('secur32.dll');

    // 1. SAM-compatible имя (CORP\ivanov или просто ivanov)
    String? samName;
    {
      final getUserNameEx = secur32.lookupFunction<
          ffi.Int32 Function(ffi.Int32, ffi.Pointer<_UserNameBuffer>, ffi.Pointer<ffi.Uint32>),
          int Function(int, ffi.Pointer<_UserNameBuffer>, ffi.Pointer<ffi.Uint32>)>(
          'GetUserNameExW');
      final buf = calloc<_UserNameBuffer>();
      final len = calloc<ffi.Uint32>();
      // calloc возвращает обнулённую память — отдельно чистить буфер не нужно.
      len.value = 256; // размер буфера в символах (wchar)
      if (getUserNameEx(_nameSamCompatible, buf, len) != 0) {
        final chars = <int>[];
        for (var i = 0; i < 256; i++) {
          final c = buf.ref.data[i];
          if (c == 0) break;
          chars.add(c);
        }
        samName = String.fromCharCodes(chars);
      }
      calloc.free(buf);
      calloc.free(len);
    }

    // 2. Чистое имя пользователя (фолбэк, если secur32 недоступен)
    String? plainName;
    {
      final getUserName = advapi32.lookupFunction<GetUserNameWNative, GetUserNameWDart>(
          'GetUserNameW');
      final buf = calloc<ffi.Uint16>(256);
      final len = calloc<ffi.Uint32>();
      len.value = 256;
      if (getUserName(buf, len) != 0) {
        plainName = buf.cast<Utf16>().toDartString(length: 255);
      }
      calloc.free(buf);
      calloc.free(len);
    }

    if ((samName == null || samName.isEmpty) &&
        (plainName == null || plainName.isEmpty)) {
      return null;
    }

    // 3. Разбор SAM-имени на домен/пользователя
    String userName = plainName ?? '';
    String? domain;
    if (samName != null && samName.contains('\\')) {
      final parts = samName.split('\\');
      domain = parts[0];
      userName = parts.sublist(1).join('\\');
    }

    // 4. Имя машины: DNS FQDN, фолбэк NetBIOS
    String computerName = '';
    {
      final getComputerNameEx = kernel32.lookupFunction<
          GetComputerNameExWName, GetComputerNameExWDart>('GetComputerNameExW');
      for (final fmt in [_computerNameDnsFullyQualified, _computerNameNetBios]) {
        final len = calloc<ffi.Uint32>();
        len.value = 256;
        final buf = calloc<ffi.Uint16>(256);
        if (getComputerNameEx(fmt, buf, len) != 0) {
          computerName = buf.cast<Utf16>().toDartString(length: len.value);
          calloc.free(buf);
          calloc.free(len);
          break;
        }
        calloc.free(buf);
        calloc.free(len);
      }
    }

    return WindowsIdentity._(
      userName: userName,
      domainName: (domain != null && domain.isNotEmpty) ? domain : null,
      computerName: computerName,
    );
  }

  /// Снимок для login/телеметрии
  static Map<String, dynamic>? snapshot() {
    final ident = instance.collect();
    if (ident == null) return null;
    return {
      'windows_user': ident.userName,
      if (ident.domainName != null) 'windows_domain': ident.domainName,
      'computer_name': ident.computerName,
      'is_domain_user': ident.isDomainUser,
    };
  }
}
