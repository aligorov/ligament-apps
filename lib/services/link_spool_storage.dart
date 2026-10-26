import 'dart:convert';
import 'dart:io';
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
class LinkSpoolStorage {
  LinkSpoolStorage({
    required this.sessionId,
    Directory? storageDir,
    this.maxSpoolBytes = 1024 * 1024 * 1024, // 1 GB по умолчанию
    DebugLogService? debugLog,
  })  : _debugLog = debugLog ?? DebugLogService.instance,
        storageDir = storageDir ?? _resolveDefaultDirectory(sessionId);

  final String sessionId;
  final Directory storageDir;
  final int maxSpoolBytes;
  final DebugLogService _debugLog;

  int _currentSpoolBytes = 0;
  int _pendingCount = 0;
  bool _initialized = false;

  int get currentSpoolBytes => _currentSpoolBytes;
  bool get hasPendingChunks => _pendingCount > 0;

  static Directory _resolveDefaultDirectory(String sessionId) {
    if (Platform.isWindows) {
      final programData =
          Platform.environment['ProgramData'] ?? r'C:\ProgramData';
      return Directory('$programData\\Ligament\\Spool\\$sessionId');
    }
    return Directory(
        '${Directory.systemTemp.path}${Platform.pathSeparator}Ligament${Platform.pathSeparator}Spool${Platform.pathSeparator}$sessionId');
  }

  Future<void> _ensureInitialized() async {
    if (_initialized) return;
    if (!await storageDir.exists()) {
      await storageDir.create(recursive: true);
    }
    await _recalculateBytes();
    _initialized = true;
  }

  Future<void> _recalculateBytes() async {
    var total = 0;
    var count = 0;
    try {
      if (await storageDir.exists()) {
        await for (final entity in storageDir.list(followLinks: false)) {
          if (entity is File && entity.path.endsWith('.spool')) {
            total += await entity.length();
            count++;
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

  Future<void> writeBatch(int batchIndex, Map<String, dynamic> batchData) async {
    await _ensureInitialized();
    final jsonStr = jsonEncode(batchData);
    final bytes = utf8.encode(jsonStr);

    if (_currentSpoolBytes + bytes.length > maxSpoolBytes) {
      _debugLog.record('recorder.spool.quota_exceeded', fields: {
        'session_id': sessionId,
        'current_bytes': _currentSpoolBytes,
        'needed_bytes': bytes.length,
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

    await tmpFile.writeAsBytes(bytes, flush: true);
    await tmpFile.rename(targetFile.path);

    _currentSpoolBytes += bytes.length;
    _pendingCount++;
    _debugLog.record('recorder.spool.write', fields: {
      'session_id': sessionId,
      'batch_seq': batchIndex,
      'bytes': bytes.length,
      'total_spool_bytes': _currentSpoolBytes,
    });
  }

  Future<Map<String, dynamic>?> readBatch(File file) async {
    try {
      if (!await file.exists()) return null;
      final content = await file.readAsString();
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
        _currentSpoolBytes = (_currentSpoolBytes - len).clamp(0, 0x7fffffffffffffff);
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
