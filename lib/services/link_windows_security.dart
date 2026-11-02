import 'dart:ffi' as ffi;
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:win32_registry/win32_registry.dart';

/// Вспомогательный класс безопасности и интеграции с Windows для Ligament LINK.
/// Включает DLP-фильтрацию паролей и поиск активного пользовательского профиля.
class LinkWindowsSecurity {
  LinkWindowsSecurity._();

  static bool _initialized = false;
  static int Function(ffi.Pointer<Utf16>)? _registerClipboardFormatW;
  static int Function(int)? _isClipboardFormatAvailable;

  static void _init() {
    if (_initialized) return;
    _initialized = true;
    if (kIsWeb || !Platform.isWindows) return;
    try {
      final user32 = ffi.DynamicLibrary.open('user32.dll');
      _registerClipboardFormatW = user32.lookupFunction<
          ffi.Uint32 Function(ffi.Pointer<Utf16>),
          int Function(ffi.Pointer<Utf16>)>('RegisterClipboardFormatW');
      _isClipboardFormatAvailable = user32.lookupFunction<
          ffi.Int32 Function(ffi.Uint32),
          int Function(int)>('IsClipboardFormatAvailable');
    } catch (_) {}
  }

  /// Проверяет, помечен ли буфер обмена как чувствительный (пароли KeePass, 1Password, Bitwarden).
  /// Форматы:
  /// - 'Clipboard Viewer Ignore'
  /// - 'ExcludeClipboardContentFromMonitor'
  /// - 'CanIncludeInClipboardHistory'
  static bool isSensitiveClipboard() {
    if (kIsWeb || !Platform.isWindows) return false;
    _init();
    final reg = _registerClipboardFormatW;
    final isAvail = _isClipboardFormatAvailable;
    if (reg == null || isAvail == null) return false;

    const formatNames = [
      'Clipboard Viewer Ignore',
      'ExcludeClipboardContentFromMonitor',
      'CanIncludeInClipboardHistory',
    ];

    for (final name in formatNames) {
      final ptr = name.toNativeUtf16();
      try {
        final fmt = reg(ptr);
        if (fmt != 0 && isAvail(fmt) != 0) {
          return true;
        }
      } catch (_) {
      } finally {
        calloc.free(ptr);
      }
    }
    return false;
  }

  /// Определяет путь к профилю активного пользователя (например, C:\Users\aligorov)
  /// из-под системной службы или интерактивного контекста.
  static String? findActiveUserProfile() {
    if (kIsWeb || !Platform.isWindows) return null;

    // 1. Попытка через реестр ProfileList и смонтированные пользовательские кусты HKEY_USERS
    try {
      final profileListKey = Registry.openPath(
        RegistryHive.localMachine,
        path: r'SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList',
      );
      final subkeys = profileListKey.subkeyNames;
      profileListKey.close();

      // Пользовательские SID начинаются с S-1-5-21-
      final userSids = subkeys.where((s) => s.startsWith('S-1-5-21-')).toList();
      for (final sid in userSids) {
        // Проверяем, смонтирован ли пользователь в HKEY_USERS (значит залогинен)
        bool isLoaded = false;
        try {
          final userHive = Registry.openPath(RegistryHive.allUsers, path: sid);
          userHive.close();
          isLoaded = true;
        } catch (_) {}

        if (isLoaded) {
          final sidKey = Registry.openPath(
            RegistryHive.localMachine,
            path: 'SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\ProfileList\\$sid',
          );
          final pathVal = sidKey.getValueAsString('ProfileImagePath');
          sidKey.close();
          if (pathVal != null &&
              !pathVal.toLowerCase().contains('systemprofile') &&
              Directory(pathVal).existsSync()) {
            return pathVal;
          }
        }
      }
    } catch (_) {}

    // 2. Если через HKEY_USERS не нашли, ищем единственный пользовательский каталог в C:\Users
    try {
      const usersRoot = 'C:\\Users';
      final dir = Directory(usersRoot);
      if (dir.existsSync()) {
        final candidates = <String>[];
        for (final entity in dir.listSync()) {
          if (entity is Directory) {
            final name = entity.uri.pathSegments.where((s) => s.isNotEmpty).last.toLowerCase();
            if (name != 'public' &&
                name != 'default' &&
                name != 'default user' &&
                name != 'all users' &&
                !name.contains('systemprofile')) {
              candidates.add(entity.path);
            }
          }
        }
        if (candidates.length == 1) {
          return candidates.first;
        }
      }
    } catch (_) {}

    return null;
  }
}
