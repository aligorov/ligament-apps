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

  /// Проверяет, помечен ли буфер обмена как чувствительный (пароли KeePass, 1Password).
  /// Форматы:
  /// - 'Clipboard Viewer Ignore' (KeePass, KeePassXC)
  /// - 'ExcludeClipboardContentFromMonitor' (1Password)
  /// Примечание: 'CanIncludeInClipboardHistory' НЕ используется, так как Windows 10/11
  /// выставляет его для обычного текста, что ложно блокировало синхронизацию.
  static bool isSensitiveClipboard() {
    if (kIsWeb || !Platform.isWindows) return false;
    _init();
    final reg = _registerClipboardFormatW;
    final isAvail = _isClipboardFormatAvailable;
    if (reg == null || isAvail == null) return false;

    const formatNames = [
      'Clipboard Viewer Ignore',
      'ExcludeClipboardContentFromMonitor',
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

  /// Быстрое и безопасное перечисление букв дисков Windows без блокировок ввода-вывода (I/O)
  /// через системный вызов GetLogicalDrives() в kernel32.dll.
  /// Исключает флоппи-дисководы A: и B: и сетевые таймауты.
  static List<String> getWindowsDrives() {
    if (kIsWeb || !Platform.isWindows) return const [];
    try {
      final kernel32 = ffi.DynamicLibrary.open('kernel32.dll');
      final getLogicalDrives = kernel32.lookupFunction<
          ffi.Uint32 Function(),
          int Function()>('GetLogicalDrives');
      final mask = getLogicalDrives();
      final result = <String>[];
      // Индексы 0 и 1 соответствуют A: и B: (флоппи). Начинаем с 2 (C:).
      for (int i = 2; i < 26; i++) {
        if ((mask & (1 << i)) != 0) {
          result.add('${String.fromCharCode(65 + i)}:\\');
        }
      }
      return result.isNotEmpty ? result : ['C:\\'];
    } catch (_) {
      return ['C:\\'];
    }
  }
}
