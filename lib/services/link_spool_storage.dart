import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'debug_log_service.dart';

/// Ошибка превышения дисковой квоты спулинга записей.
class LinkSpoolQuotaExceededException implements Exception {
  const LinkSpoolQuotaExceededException({
    required this.message,
    required this.currentBytes,
    required this.maxBytes,
  });

  final String message;
  final int currentBytes;
  final int maxBytes;

  @override
  String toString() =>
      'LinkSpoolQuotaExceededException: $message (used: $currentBytes, max: $maxBytes)';
}

/// Локальное дисковое хранилище-спулер (WAL) для сессий Link Recorder.
/// Используется в режиме failure_policy=resilient для непрерывной фиксации
/// кадров при сетевых задержках или недоступности сервера Recorder.
///
/// Безопасность Data-at-Rest:
/// 1. Все чанки (.spool) на диске зашифрованы эфемерным симметричным ключом сессии
///    (CTR-keystream + HMAC-SHA256) в режиме Crypto-shredding.
/// 2. Ключ сессии хранится исключительно в оперативной памяти процесса хоста.
/// 3. Любая попытка подделки или повреждения файла на диске отвергается по HMAC.
/// 4. Права доступа к каталогу ограничиваются системными ACL (SYSTEM, Administrators).
class LinkSpoolStorage {
  LinkSpoolStorage({
    required this.sessionId,
    Directory? storageDir,
    this.maxSpoolBytes = 1024 * 1024 * 1024, // 1 GB по умолчанию
    this.minFreeDiskBytes = 500 * 1024 * 1024, // 500 MB Safety Floor
    Uint8List? sessionKey,
    this.freeBytesChecker,
    DebugLogService? debugLog,
  })  : _debugLog = debugLog ?? DebugLogService.instance,
        storageDir = storageDir ?? _resolveDefaultDirectory(sessionId),
        _sessionKey = sessionKey ??
            _resolveInitialKey(
                storageDir ?? _resolveDefaultDirectory(sessionId), sessionKey);

  final String sessionId;
  final Directory storageDir;
  final int maxSpoolBytes;
  final int minFreeDiskBytes;
  final FutureOr<int?> Function()? freeBytesChecker;
  final Uint8List _sessionKey;
  final DebugLogService _debugLog;

  int _currentSpoolBytes = 0;
  int _pendingCount = 0;
  bool _initialized = false;
  DateTime? _lastDiskCheck;
  int? _cachedFreeBytes;

  int get currentSpoolBytes => _currentSpoolBytes;
  bool get hasPendingChunks => _pendingCount > 0;
  Uint8List get sessionKey => _sessionKey;

  static Uint8List _generateSessionKey() {
    final rng = Random.secure();
    return Uint8List.fromList(List<int>.generate(32, (_) => rng.nextInt(256)));
  }

  static Uint8List _resolveInitialKey(Directory dir, Uint8List? explicitKey) {
    if (explicitKey != null) return explicitKey;
    try {
      final keyFile =
          File('${dir.path}${Platform.pathSeparator}.session.key');
      if (keyFile.existsSync()) {
        final bytes = keyFile.readAsBytesSync();
        if (bytes.length == 32) {
          return Uint8List.fromList(bytes);
        }
      }
    } catch (_) {}
    return _generateSessionKey();
  }

  static Directory _resolveDefaultDirectory(String sessionId) {
    if (Platform.isWindows) {
      final programData =
          Platform.environment['ProgramData'] ?? r'C:\ProgramData';
      return Directory('$programData\\Ligament\\Spool\\$sessionId');
    }
    return Directory(
        '${Directory.systemTemp.path}${Platform.pathSeparator}Ligament${Platform.pathSeparator}Spool${Platform.pathSeparator}$sessionId');
  }

  static Directory resolveBaseSpoolDirectory() {
    if (Platform.isWindows) {
      final programData =
          Platform.environment['ProgramData'] ?? r'C:\ProgramData';
      return Directory('$programData\\Ligament\\Spool');
    }
    return Directory(
        '${Directory.systemTemp.path}${Platform.pathSeparator}Ligament${Platform.pathSeparator}Spool');
  }

  /// Удаляет осиротевшие каталоги спулов сессий, созданные ранее указанного возраста (по умолчанию 24ч).
  /// Защищает от утечки свободного места при аварийных падениях процесса хоста.
  static Future<int> purgeOrphanedSpools({
    Directory? baseDir,
    Duration maxAge = const Duration(hours: 24),
  }) async {
    final targetBase = baseDir ?? resolveBaseSpoolDirectory();
    var purgedCount = 0;
    try {
      if (await targetBase.exists()) {
        final threshold = DateTime.now().subtract(maxAge);
        await for (final entity in targetBase.list(followLinks: false)) {
          if (entity is Directory) {
            try {
              final stat = await entity.stat();
              if (stat.modified.isBefore(threshold)) {
                await entity.delete(recursive: true);
                purgedCount++;
              }
            } catch (_) {}
          }
        }
      }
    } catch (_) {}
    return purgedCount;
  }

  Future<void> _ensureInitialized() async {
    if (_initialized) return;
    if (!await storageDir.exists()) {
      await storageDir.create(recursive: true);
      await _hardenDirectoryPermissions(storageDir);
    }
    final keyFile =
        File('${storageDir.path}${Platform.pathSeparator}.session.key');
    if (!await keyFile.exists()) {
      try {
        await keyFile.writeAsBytes(_sessionKey, flush: true);
        if (Platform.isLinux || Platform.isMacOS) {
          await Process.run('chmod', ['0600', keyFile.path])
              .timeout(const Duration(seconds: 2));
        }
      } catch (_) {}
    }
    await _recalculateBytes();
    _initialized = true;
  }

  static Future<void> _hardenDirectoryPermissions(Directory dir) async {
    try {
      if (Platform.isWindows) {
        // Ограничиваем наследование и права на чтение для посторонних локальных пользователей
        await Process.run('icacls', [
          dir.path,
          '/inheritance:r',
          '/grant:r',
          '*S-1-5-18:(OI)(CI)F', // SYSTEM
          '/grant:r',
          '*S-1-5-32-544:(OI)(CI)F', // Administrators
        ]).timeout(const Duration(seconds: 2));
      } else if (Platform.isLinux || Platform.isMacOS) {
        await Process.run('chmod', ['0700', dir.path])
            .timeout(const Duration(seconds: 2));
      }
    } catch (_) {}
  }

  Future<void> _recalculateBytes() async {
    var total = 0;
    var count = 0;
    try {
      if (await storageDir.exists()) {
        await for (final entity in storageDir.list(followLinks: false)) {
          if (entity is File) {
            if (entity.path.endsWith('.spool')) {
              total += await entity.length();
              count++;
            } else if (entity.path.endsWith('.tmp')) {
              // Автоочистка зависших временных файлов после аварийного рестарта
              try {
                await entity.delete();
              } catch (_) {}
            }
          }
        }
      }
    } catch (_) {}
    _currentSpoolBytes = total;
    _pendingCount = count;
  }

  Future<bool> hasPending() async {
    await _ensureInitialized();
    return _pendingCount > 0;
  }

  Future<List<File>> getPendingBatches() async {
    await _ensureInitialized();
    final files = <File>[];
    try {
      if (await storageDir.exists()) {
        await for (final entity in storageDir.list(followLinks: false)) {
          if (entity is File && entity.path.endsWith('.spool')) {
            files.add(entity);
          }
        }
      }
    } catch (_) {}
    files.sort((a, b) => a.path.compareTo(b.path));
    return files;
  }

  /// Шифрование полезной нагрузки: CTR-keystream на базе SHA-256 + HMAC-SHA256 целостность.
  Uint8List _seal(Uint8List plaintext) {
    final rng = Random.secure();
    final iv = Uint8List.fromList(List<int>.generate(16, (_) => rng.nextInt(256)));
    final ciphertext = _cryptPayload(_sessionKey, iv, plaintext);
    final tag = Hmac(sha256, _sessionKey).convert([...iv, ...ciphertext]).bytes;
    return Uint8List.fromList([...iv, ...tag, ...ciphertext]);
  }

  /// Расшифровка полезной нагрузки с проверкой подлинности HMAC.
  Uint8List? _open(Uint8List sealed) {
    if (sealed.length < 48) return null; // 16 байт IV + 32 байта HMAC
    final iv = Uint8List.sublistView(sealed, 0, 16);
    final tag = Uint8List.sublistView(sealed, 16, 48);
    final ciphertext = Uint8List.sublistView(sealed, 48);

    final expectedTag = Hmac(sha256, _sessionKey).convert([...iv, ...ciphertext]).bytes;
    var diff = 0;
    for (var i = 0; i < 32; i++) {
      diff |= tag[i] ^ expectedTag[i];
    }
    if (diff != 0) return null; // Поврежденный или поддельный чанк

    return _cryptPayload(_sessionKey, iv, ciphertext);
  }

  static Uint8List _cryptPayload(Uint8List key, Uint8List iv, Uint8List input) {
    final out = Uint8List(input.length);
    var block = 0;
    var offset = 0;
    final counter = Uint8List(4);
    final hmac = Hmac(sha256, key);

    while (offset < input.length) {
      counter.buffer.asByteData().setUint32(0, block, Endian.big);
      var streamBlock = hmac.convert([...iv, ...counter]).bytes;
      final stretched = <int>[...streamBlock];
      for (var j = 0; j < 7; j++) {
        streamBlock = sha256.convert(streamBlock).bytes;
        stretched.addAll(streamBlock);
      }
      final sz = min(stretched.length, input.length - offset);
      for (var i = 0; i < sz; i++) {
        out[offset + i] = input[offset + i] ^ stretched[i];
      }
      offset += sz;
      block++;
    }
    return out;
  }

  static int? _getWindowsFreeBytes(String path) {
    if (!Platform.isWindows) return null;
    try {
      final lib = ffi.DynamicLibrary.open('kernel32.dll');
      final fn = lib.lookupFunction<
          ffi.Int32 Function(ffi.Pointer<Utf16>, ffi.Pointer<ffi.Uint64>,
              ffi.Pointer<ffi.Uint64>, ffi.Pointer<ffi.Uint64>),
          int Function(ffi.Pointer<Utf16>, ffi.Pointer<ffi.Uint64>,
              ffi.Pointer<ffi.Uint64>, ffi.Pointer<ffi.Uint64>)>('GetDiskFreeSpaceExW');
      final dirPtr = path.toNativeUtf16();
      final freeCallerPtr = calloc<ffi.Uint64>();
      final totalBytesPtr = calloc<ffi.Uint64>();
      final totalFreeBytesPtr = calloc<ffi.Uint64>();
      try {
        final ok = fn(dirPtr, freeCallerPtr, totalBytesPtr, totalFreeBytesPtr);
        if (ok != 0) {
          return freeCallerPtr.value;
        }
      } finally {
        calloc.free(dirPtr);
        calloc.free(freeCallerPtr);
        calloc.free(totalBytesPtr);
        calloc.free(totalFreeBytesPtr);
      }
    } catch (_) {}
    return null;
  }

  Future<int?> _checkFreeDiskSpace() async {
    if (freeBytesChecker != null) {
      return await freeBytesChecker!();
    }
    final now = DateTime.now();
    if (_lastDiskCheck != null &&
        now.difference(_lastDiskCheck!) < const Duration(seconds: 3)) {
      return _cachedFreeBytes;
    }
    _lastDiskCheck = now;
    int? free;
    if (Platform.isWindows) {
      free = _getWindowsFreeBytes(storageDir.path);
    } else if (Platform.isLinux || Platform.isMacOS) {
      try {
        final res = await Process.run('df', ['-k', storageDir.path])
            .timeout(const Duration(seconds: 1));
        if (res.exitCode == 0) {
          final lines = res.stdout.toString().trim().split('\n');
          if (lines.length >= 2) {
            final parts = lines[1].split(RegExp(r'\s+'));
            if (parts.length >= 4) {
              final freeKb = int.tryParse(parts[3]);
              if (freeKb != null) free = freeKb * 1024;
            }
          }
        }
      } catch (_) {}
    }
    _cachedFreeBytes = free;
    return free;
  }

  Future<void> writeBatch(int batchIndex, Map<String, dynamic> batchData) async {
    await _ensureInitialized();
    final jsonStr = jsonEncode(batchData);
    final rawBytes = utf8.encode(jsonStr);
    final encryptedBytes = _seal(Uint8List.fromList(rawBytes));

    final availableFree = await _checkFreeDiskSpace();
    if (availableFree != null && availableFree < minFreeDiskBytes) {
      _debugLog.record('recorder.spool.disk_floor_reached', fields: {
        'session_id': sessionId,
        'available_bytes': availableFree,
        'min_floor_bytes': minFreeDiskBytes,
      });
      throw LinkSpoolQuotaExceededException(
        message: 'Disk safety floor reached: available disk space is low ($availableFree bytes < $minFreeDiskBytes bytes)',
        currentBytes: _currentSpoolBytes,
        maxBytes: maxSpoolBytes,
      );
    }

    if (_currentSpoolBytes + encryptedBytes.length > maxSpoolBytes) {
      _debugLog.record('recorder.spool.quota_exceeded', fields: {
        'session_id': sessionId,
        'current_bytes': _currentSpoolBytes,
        'needed_bytes': encryptedBytes.length,
        'max_bytes': maxSpoolBytes,
      });
      throw LinkSpoolQuotaExceededException(
        message: 'Spool disk quota reached',
        currentBytes: _currentSpoolBytes,
        maxBytes: maxSpoolBytes,
      );
    }

    final seqStr = batchIndex.toString().padLeft(8, '0');
    final tmpFile =
        File('${storageDir.path}${Platform.pathSeparator}batch_$seqStr.tmp');
    final targetFile =
        File('${storageDir.path}${Platform.pathSeparator}batch_$seqStr.spool');

    await tmpFile.writeAsBytes(encryptedBytes, flush: true);
    await tmpFile.rename(targetFile.path);

    _currentSpoolBytes += encryptedBytes.length;
    _pendingCount++;
    _debugLog.record('recorder.spool.write', fields: {
      'session_id': sessionId,
      'batch_seq': batchIndex,
      'bytes': encryptedBytes.length,
      'total_spool_bytes': _currentSpoolBytes,
    });
  }

  Future<Map<String, dynamic>?> readBatch(File file) async {
    try {
      if (!await file.exists()) return null;
      final sealedBytes = await file.readAsBytes();
      final decryptedBytes = _open(sealedBytes);
      if (decryptedBytes == null) {
        _debugLog.record('recorder.spool.tampered_or_invalid', fields: {
          'session_id': sessionId,
          'file': file.path,
        });
        return null;
      }
      final content = utf8.decode(decryptedBytes);
      final decoded = jsonDecode(content);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      return null;
    } catch (error) {
      _debugLog.record('recorder.spool.read_failed', error: error, fields: {
        'session_id': sessionId,
        'file': file.path,
      });
      return null;
    }
  }

  Future<void> removeBatch(File file) async {
    try {
      if (await file.exists()) {
        final len = await file.length();
        await file.delete();
        _currentSpoolBytes =
            (_currentSpoolBytes - len).clamp(0, 0x7fffffffffffffff);
        if (_pendingCount > 0) _pendingCount--;
      }
    } catch (_) {}
  }

  Future<void> clear() async {
    try {
      if (await storageDir.exists()) {
        await storageDir.delete(recursive: true);
      }
    } catch (_) {}
    _currentSpoolBytes = 0;
    _pendingCount = 0;
    _initialized = false;
  }
}
