import 'dart:ffi' as ffi;
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

/// Вспомогательный класс безопасности и интеграции с Windows для Ligament LINK.
/// Включает DLP-фильтрацию паролей.
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
}
