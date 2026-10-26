import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

/// Метаданные и полезная нагрузка кадра записи с достоверными размерами и кодеком.
class RecordedFrameInfo {
  final Uint8List payload;
  final int width;
  final int height;
  final String codec; // 'jpeg' | 'png' | 'webp'

  const RecordedFrameInfo({
    required this.payload,
    required this.width,
    required this.height,
    required this.codec,
  });
}

/// Парсер заголовка изображения без декодирования пикселей (PNG, JPEG, WebP).
RecordedFrameInfo? parseImageHeader(Uint8List bytes) {
  if (bytes.length < 8) return null;

  // 1. PNG: 89 50 4E 47 0D 0A 1A 0A
  if (bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47 &&
      bytes[4] == 0x0D &&
      bytes[5] == 0x0A &&
      bytes[6] == 0x1A &&
      bytes[7] == 0x0A &&
      bytes.length >= 24) {
    final width = (bytes[16] << 24) | (bytes[17] << 16) | (bytes[18] << 8) | bytes[19];
    final height = (bytes[20] << 24) | (bytes[21] << 16) | (bytes[22] << 8) | bytes[23];
    return RecordedFrameInfo(
      payload: bytes,
      width: width,
      height: height,
      codec: 'png',
    );
  }

  // 2. JPEG: FF D8 FF
  if (bytes[0] == 0xFF && bytes[1] == 0xD8) {
    int offset = 2;
    while (offset < bytes.length - 8) {
      if (bytes[offset] != 0xFF) {
        offset++;
        continue;
      }
      while (offset < bytes.length && bytes[offset] == 0xFF) {
        offset++;
      }
      if (offset >= bytes.length) break;
      final marker = bytes[offset];
      offset++;

      if (marker == 0xD8 || marker == 0xD9 || (marker >= 0xD0 && marker <= 0xD7)) {
        continue;
      }

      if (offset + 2 > bytes.length) break;
      final len = (bytes[offset] << 8) | bytes[offset + 1];

      // SOF0 (0xC0), SOF1 (0xC1), SOF2 (0xC2)
      if (marker == 0xC0 || marker == 0xC1 || marker == 0xC2) {
        if (offset + 7 <= bytes.length) {
          final height = (bytes[offset + 3] << 8) | bytes[offset + 4];
          final width = (bytes[offset + 5] << 8) | bytes[offset + 6];
          return RecordedFrameInfo(
            payload: bytes,
            width: width,
            height: height,
            codec: 'jpeg',
          );
        }
      }
      offset += len;
    }
  }

  // 3. WebP: RIFF .... WEBP
  if (bytes.length >= 30 &&
      bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    if (bytes[12] == 0x56 && bytes[13] == 0x50 && bytes[14] == 0x38 && bytes[15] == 0x20) {
      if (bytes.length >= 30) {
        final width = (bytes[26] | ((bytes[27] & 0x3F) << 8));
        final height = (bytes[28] | ((bytes[29] & 0x3F) << 8));
        return RecordedFrameInfo(
          payload: bytes,
          width: width,
          height: height,
          codec: 'webp',
        );
      }
    }
    if (bytes[12] == 0x56 && bytes[13] == 0x50 && bytes[14] == 0x38 && bytes[15] == 0x4C) {
      if (bytes.length >= 25 && bytes[20] == 0x2F) {
        final b1 = bytes[21];
        final b2 = bytes[22];
        final b3 = bytes[23];
        final b4 = bytes[24];
        final width = 1 + (((b2 & 0x3F) << 8) | b1);
        final height = 1 + (((b4 & 0xF) << 10) | (b3 << 2) | ((b2 & 0xC0) >> 6));
        return RecordedFrameInfo(
          payload: bytes,
          width: width,
          height: height,
          codec: 'webp',
        );
      }
    }
    if (bytes[12] == 0x56 && bytes[13] == 0x50 && bytes[14] == 0x38 && bytes[15] == 0x58) {
      if (bytes.length >= 30) {
        final width = 1 + (bytes[24] | (bytes[25] << 8) | (bytes[26] << 16));
        final height = 1 + (bytes[27] | (bytes[28] << 8) | (bytes[29] << 16));
        return RecordedFrameInfo(
          payload: bytes,
          width: width,
          height: height,
          codec: 'webp',
        );
      }
    }
  }

  return null;
}

/// Подготавливает кадр для Recorder'а: проверяет формат и размеры,
/// при необходимости (BMP/TIFF) перекодирует в валидный PNG через dart:ui.
Future<RecordedFrameInfo?> prepareRecordedFrame(Uint8List rawBytes) async {
  final direct = parseImageHeader(rawBytes);
  if (direct != null && direct.width > 0 && direct.height > 0) {
    return direct;
  }
  try {
    final codec = await ui.instantiateImageCodec(rawBytes);
    final frame = await codec.getNextFrame();
    final img = frame.image;
    final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
    final w = img.width;
    final h = img.height;
    img.dispose();
    if (byteData != null) {
      return RecordedFrameInfo(
        payload: byteData.buffer.asUint8List(),
        width: w,
        height: h,
        codec: 'png',
      );
    }
  } catch (e) {
    debugPrint('prepareRecordedFrame: decode/transcode error: $e');
  }
  return null;
}

/// Конфигурация записи сессии, получаемая хостом в `session_offer.recording` (Contract v1).
class LinkRecordingConfig {
  const LinkRecordingConfig({
    this.contractVersion = 'v1',
    this.enabled = false,
    this.mandatory = false,
    this.requireFirstFrame = false,
    this.effectiveMode = 'exclude',
    this.aiAllowed = false,
    this.policyReason = '',
    this.ingestUrl = '',
    this.ingestToken = '',
    this.epoch = 1,
    this.leaseTtl = const Duration(seconds: 45),
    this.maxAckLag = const Duration(seconds: 30),
    this.maxQueueBytes = 16 * 1024 * 1024,
  });

  final String contractVersion;
  final bool enabled;
  final bool mandatory;
  final bool requireFirstFrame;
  final String effectiveMode; // record+AI, record_only, exclude
  final bool aiAllowed;
  final String policyReason;
  final String ingestUrl;
  final String ingestToken;
  final int epoch;
  final Duration leaseTtl;
  final Duration maxAckLag;
  final int maxQueueBytes;

  bool get isActive =>
      enabled && effectiveMode != 'exclude' && ingestUrl.isNotEmpty;

  static LinkRecordingConfig fromWire(Object? raw) {
    if (raw is! Map) return const LinkRecordingConfig();
    final enabled = raw['enabled'] == true;
    final mandatory = raw['mandatory'] == true;
    final mode = raw['effective_mode'] is String
        ? raw['effective_mode'] as String
        : (enabled ? 'record_only' : 'exclude');
    final leaseSec = raw['lease_ttl_seconds'] is int
        ? (raw['lease_ttl_seconds'] as int).clamp(10, 300)
        : 45;
    final lagSec = raw['max_ack_lag_seconds'] is int
        ? (raw['max_ack_lag_seconds'] as int).clamp(5, 180)
        : 30;
    return LinkRecordingConfig(
      contractVersion: raw['contract_version']?.toString() ?? 'v1',
      enabled: enabled && mode != 'exclude',
      mandatory: enabled && mandatory && mode != 'exclude',
      requireFirstFrame: enabled && (raw['require_first_frame'] == true || mandatory),
      effectiveMode: mode,
      aiAllowed: raw['ai_allowed'] == true && mode == 'record+AI',
      policyReason: raw['policy_reason']?.toString() ?? '',
      ingestUrl: raw['ingest_url']?.toString() ?? '',
      ingestToken: raw['ingest_token']?.toString() ?? '',
      epoch: raw['epoch'] is int ? (raw['epoch'] as int) : 1,
      leaseTtl: Duration(seconds: leaseSec),
      maxAckLag: Duration(seconds: lagSec),
    );
  }
}

/// Ответ долговечного подтверждения (ACK) от сервиса Recorder.
class LinkRecorderBatchAck {
  const LinkRecorderBatchAck({
    required this.ackHighWatermarkSeq,
    required this.firstFrameAcked,
    required this.leaseExpiresAt,
    this.leaseTtlMs,
  });

  final int ackHighWatermarkSeq;
  final bool firstFrameAcked;
  final DateTime leaseExpiresAt;
  final int? leaseTtlMs;
}

typedef LinkRecorderBatchSender = Future<LinkRecorderBatchAck> Function(
  Map<String, dynamic> batchPayload,
);

/// Наблюдатель захвата и событий на стороне хоста (Этапы 2, 9, 10).
/// Работает независимо от прямого P2P WebRTC и окна оператора:
/// - фильтрует события ввода (исключая печатный текст, пароли и буфер обмена);
/// - ограничивает RAM-очередь;
/// - проверяет ACK первого кадра и отставание подтверждений (ACK lag / lease) для обязательных сессий.
class LinkHostRecorder {
  LinkHostRecorder({
    required this.sessionId,
    required this.config,
    LinkRecorderBatchSender? sendBatch,
    this.onMandatoryViolation,
    DateTime Function()? clock,
    Stopwatch? leaseStopwatch,
    Duration? stopFlushTimeout,
  })  : _clock = clock ?? DateTime.now,
        _startedAt = (clock ?? DateTime.now)().toUtc(),
        _leaseStopwatch = leaseStopwatch ?? Stopwatch(),
        _stopFlushTimeout =
            stopFlushTimeout ?? const Duration(seconds: 25),
        sendBatch = sendBatch ??
            ((batch) => defaultHttpSendBatch(
                  config.ingestUrl,
                  config.ingestToken,
                  batch,
                )) {
    if (sessionId.toLowerCase().startsWith('link_')) {
      throw const FormatException(
        'Temporary link_<agentId> identifier is forbidden for Recorder archive',
      );
    }
  }

  static HttpClient? _sharedHttpClient;

  static HttpClient _getSharedClient() {
    return _sharedHttpClient ??= (HttpClient()..connectionTimeout = const Duration(seconds: 8));
  }

  static void closeSharedClient() {
    _sharedHttpClient?.close(force: true);
    _sharedHttpClient = null;
  }

  @visibleForTesting
  static bool isSecureIngestUri(Uri? uri) {
    if (uri == null) return false;
    final scheme = uri.scheme.toLowerCase();
    if (scheme == 'https') return true;
    if (scheme != 'http') return false;
    final host = uri.host.toLowerCase();
    if (host == 'localhost') return true;
    final address = InternetAddress.tryParse(host);
    return address != null && address.isLoopback;
  }

  static const Duration _httpTimeout = Duration(seconds: 10);
  static const int _maxAckBodyBytes = 64 * 1024;

  static Future<String> _readAckBody(
    HttpClientResponse response,
    Duration timeLimit,
  ) {
    final completer = Completer<String>();
    final bytes = <int>[];
    StreamSubscription<List<int>>? subscription;
    Timer? timeout;
    void finish(void Function() complete) {
      if (completer.isCompleted) return;
      timeout?.cancel();
      complete();
    }

    subscription = response.listen(
      (chunk) {
        if (completer.isCompleted) return;
        if (bytes.length + chunk.length > _maxAckBodyBytes) {
          unawaited(subscription?.cancel());
          finish(() => completer.completeError(
              const FormatException('Recorder ACK body too large')));
          return;
        }
        bytes.addAll(chunk);
      },
      onError: (Object error, StackTrace stackTrace) {
        finish(() => completer.completeError(error, stackTrace));
      },
      onDone: () {
        finish(() => completer.complete(utf8.decode(bytes)));
      },
      cancelOnError: true,
    );
    timeout = Timer(timeLimit, () {
      unawaited(subscription?.cancel());
      finish(() => completer.completeError(
          TimeoutException('Recorder ACK body timeout', timeLimit)));
    });
    return completer.future;
  }

  static Future<LinkRecorderBatchAck> defaultHttpSendBatch(
    String ingestUrl,
    String ingestToken,
    Map<String, dynamic> batch, {
    HttpClient? client,
    Duration timeout = _httpTimeout,
  }) async {
    final uri = Uri.tryParse(ingestUrl);
    if (!isSecureIngestUri(uri)) {
      throw const FormatException('recorder_insecure_ingest');
    }
    final httpClient = client ?? _getSharedClient();
    final request = await httpClient.postUrl(uri!);
    request.headers.contentType = ContentType.json;
    if (ingestToken.isNotEmpty) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $ingestToken');
    }
    request.add(utf8.encode(jsonEncode(batch)));
    final response = await request.close().timeout(timeout);
    final body = await _readAckBody(response, timeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException('Recorder ingest status ${response.statusCode}');
    }
    final decoded = jsonDecode(body);
    if (decoded is! Map) {
      throw const FormatException('Invalid Recorder ACK JSON');
    }
    if (decoded['ack_high_watermark_seq'] == null || decoded['ack_high_watermark_seq'] is! num) {
      throw const FormatException('Recorder ACK missing required ack_high_watermark_seq');
    }
    if (decoded['lease_expires_at'] == null) {
      throw const FormatException('Recorder ACK missing required lease_expires_at');
    }
    final leaseExpiresAt = DateTime.tryParse(decoded['lease_expires_at']?.toString() ?? '');
    if (leaseExpiresAt == null) {
      throw const FormatException('Recorder ACK invalid lease_expires_at');
    }
    final leaseTtlMs = decoded['lease_ttl_ms'] is num
        ? (decoded['lease_ttl_ms'] as num).toInt()
        : null;
    return LinkRecorderBatchAck(
      ackHighWatermarkSeq: (decoded['ack_high_watermark_seq'] as num).toInt(),
      firstFrameAcked: decoded['first_frame_acked'] == true,
      leaseExpiresAt: leaseExpiresAt,
      leaseTtlMs: leaseTtlMs,
    );
  }

  static const Set<String> _allowedNonPrintableKeys = {
    'enter', 'return', 'tab', 'escape', 'esc', 'backspace', 'delete', 'insert',
    'home', 'end', 'pageup', 'page up', 'pagedown', 'page down',
    'arrowup', 'arrow up', 'arrowdown', 'arrow down',
    'arrowleft', 'arrow left', 'arrowright', 'arrow right',
    'up', 'down', 'left', 'right', 'space',
    'capslock', 'caps lock', 'numlock', 'num lock', 'scrolllock', 'scroll lock',
    'f1', 'f2', 'f3', 'f4', 'f5', 'f6', 'f7', 'f8', 'f9', 'f10', 'f11', 'f12',
    'control', 'ctrl', 'control left', 'control right', 'ctrl left', 'ctrl right',
    'alt', 'alt left', 'alt right',
    'shift', 'shift left', 'shift right',
    'meta', 'meta left', 'meta right', 'win', 'super',
  };

  final String sessionId;
  final LinkRecordingConfig config;
  final LinkRecorderBatchSender sendBatch;
  final void Function(String reason)? onMandatoryViolation;
  final DateTime Function() _clock;
  DateTime _startedAt;

  static const int maxBatchBytes = 2 * 1024 * 1024;
  static const int maxBatchFrames = 20;
  static const int maxBatchEvents = 200;

  final List<Map<String, dynamic>> _pendingFrames = [];
  final List<Map<String, dynamic>> _pendingEvents = [];
  Uint8List? _lastFramePayload;
  String? _lastMonitorId;
  int _queuedBytes = 0;
  int _nextSeq = 0;
  int _ackedSeq = 0;
  bool _firstFrameAcked = false;
  DateTime? _lastAckAt;
  final Stopwatch _leaseStopwatch;
  Duration? _leaseTtl;
  DateTime? _desktopGraceUntil;
  Timer? _flushTimer;
  bool _stopped = false;
  bool _sessionEndedRecorded = false;
  bool _tailFlushed = true;
  Future<bool>? _activeFlush;

  int get nextSeq => _nextSeq;
  int get ackedSeq => _ackedSeq;
  bool get isFirstFrameAcked => !config.enabled || _firstFrameAcked;
  bool get firstFrameAcked => _firstFrameAcked;
  bool get isTailFlushed => _tailFlushed && _pendingFrames.isEmpty && _pendingEvents.isEmpty;
  int get queuedBytes => _queuedBytes;

  void notifyDesktopChanged() {
    final now = _clock().toUtc();
    // Льготный период при смене рабочего стола (≤ 10 с, без продления, пока он активен)
    if (_desktopGraceUntil == null || now.isAfter(_desktopGraceUntil!)) {
      _desktopGraceUntil = now.add(const Duration(seconds: 10));
    }
  }

  void start() {
    _startedAt = _clock().toUtc();
    if (!config.enabled || _stopped || _flushTimer != null) return;

    if (config.ingestUrl.isNotEmpty && (config.mandatory || config.requireFirstFrame)) {
      final uri = Uri.tryParse(config.ingestUrl);
      if (!isSecureIngestUri(uri)) {
        _triggerMandatoryStop('recorder_insecure_ingest');
        return;
      }
    }

    if (_nextSeq == 0 && _pendingEvents.isEmpty) {
      _nextSeq++;
      final startEvent = {
        'seq': _nextSeq,
        'event_type': 'session_started',
        'source': 'session_lifecycle',
        'occurred_at': _clock().toUtc().toIso8601String(),
        'metadata': {'mode': config.effectiveMode},
      };
      _pendingEvents.add(startEvent);
      _queuedBytes += utf8.encode(jsonEncode(startEvent)).length;
    }
    _flushTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      unawaited(flushAndVerifyHealth());
    });
  }

  final Duration _stopFlushTimeout;

  Future<bool> stop({String reason = ''}) async {
    _flushTimer?.cancel();
    _flushTimer = null;
    while (_activeFlush != null) {
      try {
        await _activeFlush!.timeout(_stopFlushTimeout);
      } on TimeoutException {
        _tailFlushed = false;
        _stopped = true;
        return false;
      } catch (_) {}
    }
    if (!config.enabled) {
      _stopped = true;
      return true;
    }
    _stopped = true;
    if (!_sessionEndedRecorded) {
      _sessionEndedRecorded = true;
      _nextSeq++;
      final isViolation = reason.isNotEmpty &&
          reason != 'normal' &&
          reason != 'user_disconnected' &&
          reason != 'session_ended';
      final endEvent = {
        'seq': _nextSeq,
        'event_type': isViolation ? 'mandatory_violation' : 'session_ended',
        'source': 'session_lifecycle',
        'occurred_at': _clock().toUtc().toIso8601String(),
        'metadata': {
          'reason': reason.isNotEmpty ? reason : 'normal',
          if (isViolation) 'violation': reason,
        },
      };
      _pendingEvents.add(endEvent);
      _queuedBytes += utf8.encode(jsonEncode(endEvent)).length;
    }
    while (_pendingFrames.isNotEmpty || _pendingEvents.isNotEmpty) {
      final prevCount = _pendingFrames.length + _pendingEvents.length;
      late final bool ok;
      try {
        ok = await _flushInternal().timeout(_stopFlushTimeout);
      } on TimeoutException {
        _tailFlushed = false;
        return false;
      } catch (_) {
        ok = false;
      }
      final newCount = _pendingFrames.length + _pendingEvents.length;
      if (!ok || newCount >= prevCount) break;
    }
    if (_pendingFrames.isNotEmpty || _pendingEvents.isNotEmpty) {
      // Потеря хвоста — фиксируем gap_marker
      _tailFlushed = false;
      _nextSeq++;
      final gapEvent = {
        'seq': _nextSeq,
        'event_type': 'gap_marker',
        'source': 'session_lifecycle',
        'occurred_at': _clock().toUtc().toIso8601String(),
        'metadata': {
          'reason': 'tail_lost',
          'dropped_frames': _pendingFrames.length,
          'dropped_events': _pendingEvents.length,
        },
      };
      _pendingFrames.clear();
      _pendingEvents.clear();
      _pendingEvents.add(gapEvent);
      try {
        await _flushInternal().timeout(_stopFlushTimeout);
      } catch (_) {}
      _pendingEvents.clear();
      _queuedBytes = 0;
    }
    return isTailFlushed;
  }

  /// Очищает команду управления от печатных символов, паролей и текста буфера обмена (Раздел 4.2).
  static Map<String, dynamic>? sanitizeInputEvent(
    Map<String, dynamic> raw, {
    required DateTime occurredAt,
  }) {
    final type = raw['type']?.toString() ?? '';
    switch (type) {
      case 'mouse_down':
      case 'mouse_up':
        return {
          'event_type': 'mouse_click',
          'source': 'remote_operator',
          'occurred_at': occurredAt.toUtc().toIso8601String(),
          'metadata': {
            'action': type,
            'button': raw['button'],
            'x': raw['x'],
            'y': raw['y'],
          },
        };
      case 'wheel':
        return {
          'event_type': 'mouse_wheel',
          'source': 'remote_operator',
          'occurred_at': occurredAt.toUtc().toIso8601String(),
          'metadata': {'delta_y': raw['deltaY']},
        };
      case 'hotkey':
        final action = raw['action']?.toString() ?? '';
        if (action.isEmpty) return null;
        return {
          'event_type': 'hotkey',
          'source': 'remote_operator',
          'occurred_at': occurredAt.toUtc().toIso8601String(),
          'metadata': {'action': action},
        };
      case 'key_up':
        return null;
      case 'key_down':
        final rawKeyStr = raw['key']?.toString() ?? '';
        final rawCharStr = raw['char']?.toString() ?? '';
        final keyName = (rawKeyStr == ' ' || rawCharStr == ' ')
            ? 'space'
            : rawKeyStr.trim().toLowerCase();
        if (keyName.isEmpty) return null;
        if (_allowedNonPrintableKeys.contains(keyName)) {
          return {
            'event_type': 'special_key',
            'source': 'remote_operator',
            'occurred_at': occurredAt.toUtc().toIso8601String(),
            'metadata': {'action': 'key_down', 'key': keyName},
          };
        }
        return {
          'event_type': 'key_input',
          'source': 'remote_operator',
          'occurred_at': occurredAt.toUtc().toIso8601String(),
          'metadata': {
            'action': 'key_down',
          },
        };
      case 'text_input':
        final text = raw['text']?.toString() ?? '';
        return {
          'event_type': 'text_input',
          'source': 'remote_operator',
          'occurred_at': occurredAt.toUtc().toIso8601String(),
          'metadata': {
            'length': text.length,
          },
        };
      case 'clipboard_set':
      case 'clipboard_get':
        return {
          'event_type': 'clipboard_meta',
          'source': 'remote_operator',
          'occurred_at': occurredAt.toUtc().toIso8601String(),
          'metadata': {
            'direction':
                type == 'clipboard_set' ? 'operator_to_host' : 'host_to_operator',
            'content_redacted': true,
          },
        };
      case 'switch_screen':
        return {
          'event_type': 'screen_switch',
          'source': 'remote_operator',
          'occurred_at': occurredAt.toUtc().toIso8601String(),
          'metadata': {'screen_id': raw['screen_id']},
        };
      case 'block_input':
        return {
          'event_type': 'block_input',
          'source': 'remote_operator',
          'occurred_at': occurredAt.toUtc().toIso8601String(),
          'metadata': {'blocked': raw['blocked'] == true},
        };
      case 'reboot':
        return {
          'event_type': 'remote_reboot',
          'source': 'remote_operator',
          'occurred_at': occurredAt.toUtc().toIso8601String(),
          'metadata': const <String, dynamic>{},
        };
      case 'file_start':
      case 'file_end':
        return {
          'event_type': 'file_transfer_meta',
          'source': 'remote_operator',
          'occurred_at': occurredAt.toUtc().toIso8601String(),
          'metadata': {
            'stage': type,
            'transfer_id': raw['transfer_id'] ?? raw['id'],
            'filename': raw['filename'],
            'size': raw['size'],
          },
        };
      default:
        return null;
    }
  }

  static bool _bytesEqual(Uint8List a, Uint8List b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  void _recalculateQueuedBytes() {
    var total = 0;
    for (final f in _pendingFrames) {
      final b64 = f['payload_base64'] as String? ?? '';
      total += b64.length * 3 ~/ 4;
    }
    for (final e in _pendingEvents) {
      total += utf8.encode(jsonEncode(e)).length;
    }
    _queuedBytes = total;
  }

  /// Добавляет кадр в ограниченную очередь (Инвариант 7, 8, 9).
  /// Для периодических снимков (`periodic`) пропускает дубликаты, если экран не изменился.
  bool enqueueFrame({
    required String frameKind,
    required Uint8List payload,
    String monitorId = 'primary',
    int width = 1920,
    int height = 1080,
    String codec = 'webp',
  }) {
    if (!config.enabled || _stopped) return true;
    if (frameKind == 'periodic' &&
        _lastFramePayload != null &&
        _lastMonitorId == monitorId &&
        _bytesEqual(_lastFramePayload!, payload)) {
      // Экран находится в состоянии покоя (простой) — не засоряем архив идентичными кадрами.
      return true;
    }
    if (_queuedBytes + payload.length > config.maxQueueBytes) {
      // Фиксируем явный gap_marker вместо бесконтрольного роста RAM.
      _nextSeq++;
      _pendingFrames.add({
        'seq': _nextSeq,
        'frame_kind': 'gap_marker',
        'monitor_id': monitorId,
        'width': width,
        'height': height,
        'codec': codec,
        'payload_base64': '',
        'captured_at': _clock().toUtc().toIso8601String(),
      });
      if (config.mandatory) {
        _triggerMandatoryStop('recorder_queue_overflow');
      }
      return false;
    }
    _lastFramePayload = Uint8List.fromList(payload);
    _lastMonitorId = monitorId;
    _nextSeq++;
    _queuedBytes += payload.length;
    _pendingFrames.add({
      'seq': _nextSeq,
      'frame_kind': frameKind,
      'monitor_id': monitorId,
      'width': width,
      'height': height,
      'codec': codec,
      'payload_base64': base64Encode(payload),
      'captured_at': _clock().toUtc().toIso8601String(),
    });
    return true;
  }

  /// Фильтрует и ставит событие ввода в очередь записи.
  void observeControlInput(Map<String, dynamic> rawInput) {
    if (!config.enabled || _stopped) return;
    final sanitized = sanitizeInputEvent(rawInput, occurredAt: _clock());
    if (sanitized == null) return;
    _nextSeq++;
    sanitized['seq'] = _nextSeq;
    final eventBytes = utf8.encode(jsonEncode(sanitized)).length;
    _pendingEvents.add(sanitized);
    _queuedBytes += eventBytes;
  }

  /// Отправляет накопленный пакет в Recorder и проверяет долговечный ACK (Инвариант 1, 2, 5).
  Future<bool> flushAndVerifyHealth() async {
    if (!config.enabled || _stopped) return true;
    if (_activeFlush != null) {
      return await _activeFlush!;
    }
    final f = _flushInternal();
    _activeFlush = f;
    try {
      return await f;
    } finally {
      _activeFlush = null;
    }
  }

  Future<bool> _flushInternal() async {
    final now = _clock().toUtc();

    if (config.ingestUrl.isNotEmpty && (config.mandatory || config.requireFirstFrame)) {
      final uri = Uri.tryParse(config.ingestUrl);
      if (uri == null || !isSecureIngestUri(uri)) {
        _triggerMandatoryStop('recorder_insecure_ingest');
        return false;
      }
    }

    final batchFrames = <Map<String, dynamic>>[];
    var currentBatchBytes = 0;
    for (final frame in _pendingFrames) {
      if (batchFrames.length >= maxBatchFrames) break;
      final b64 = frame['payload_base64'] as String? ?? '';
      final frameBytes = b64.length * 3 ~/ 4;
      if (batchFrames.isNotEmpty && currentBatchBytes + frameBytes > maxBatchBytes) {
        break;
      }
      batchFrames.add(frame);
      currentBatchBytes += frameBytes;
    }

    final batchEvents = <Map<String, dynamic>>[];
    for (final event in _pendingEvents) {
      if (batchEvents.length >= maxBatchEvents) break;
      final eventBytes = utf8.encode(jsonEncode(event)).length;
      if (batchEvents.isNotEmpty && currentBatchBytes + eventBytes > maxBatchBytes) {
        break;
      }
      batchEvents.add(event);
      currentBatchBytes += eventBytes;
    }

    if (batchFrames.isEmpty && batchEvents.isEmpty) {
      final needsLeaseKeepalive = _lastAckAt != null
          ? now.difference(_lastAckAt!) >= const Duration(seconds: 10)
          : (!config.requireFirstFrame &&
              now.difference(_startedAt) >= const Duration(seconds: 10));
      if (!needsLeaseKeepalive) {
        return _checkLeaseAndLag(now);
      }
    }

    final batch = {
      'session_id': sessionId,
      'epoch': config.epoch,
      'lease_ttl_seconds': config.leaseTtl.inSeconds,
      'frames': batchFrames,
      'events': batchEvents,
    };

    final inFlightFrameSeqs = batchFrames.map((f) => f['seq'] as int).toSet();
    final inFlightEventSeqs = batchEvents.map((e) => e['seq'] as int).toSet();

    final sendStopwatch = Stopwatch()..start();
    try {
      final ack = await sendBatch(batch);
      sendStopwatch.stop();
      final rtt = sendStopwatch.elapsed;

      if (ack.ackHighWatermarkSeq < _ackedSeq) {
        throw FormatException(
          'Recorder ACK high watermark sequence cannot decrease (was $_ackedSeq, got ${ack.ackHighWatermarkSeq})',
        );
      }
      _ackedSeq = ack.ackHighWatermarkSeq;
      if (ack.firstFrameAcked) {
        _firstFrameAcked = true;
      }
      _lastAckAt = _clock().toUtc();
      final ackNow = _lastAckAt!;

      if (ack.leaseTtlMs != null) {
        final serverTtlMs = ack.leaseTtlMs!;
        if (serverTtlMs <= 0) {
          _leaseTtl = Duration.zero;
          _triggerMandatoryStop('recorder_lease_expired');
          return false;
        } else {
          // Безопасный консервативный deadline с вычетом полного RTT
          final remainingMs = serverTtlMs - rtt.inMilliseconds;
          if (remainingMs <= 0) {
            _leaseTtl = Duration.zero;
            _triggerMandatoryStop('recorder_lease_expired');
            return false;
          }
          _leaseTtl = Duration(milliseconds: remainingMs);
        }
      } else if (config.mandatory && config.contractVersion != 'v1') {
        throw const FormatException('Recorder ACK missing required lease_ttl_ms in mandatory mode');
      } else {
        final expiresAt = ack.leaseExpiresAt.toUtc();
        _leaseTtl = expiresAt.isAfter(ackNow)
            ? expiresAt.difference(ackNow)
            : Duration.zero;
      }
      _leaseStopwatch.reset();
      _leaseStopwatch.start();

      // Удаляем только подтверждённые сервером элементы, которые реально отправлялись
      // в текущем пакете (seq <= ackHighWatermarkSeq && in inFlightFrameSeqs),
      // чтобы не потерять кадры и события, упавшие в очередь во время HTTP-запроса (LR-03, ULR-02).
      _pendingFrames.removeWhere((f) => inFlightFrameSeqs.contains(f['seq'] as int) && (f['seq'] as int) <= _ackedSeq);
      _pendingEvents.removeWhere((e) => inFlightEventSeqs.contains(e['seq'] as int) && (e['seq'] as int) <= _ackedSeq);

      _recalculateQueuedBytes();

      if ((config.requireFirstFrame || config.mandatory) && !_firstFrameAcked) {
        if (_desktopGraceUntil != null && now.isBefore(_desktopGraceUntil!)) {
          return true;
        }
        final elapsed = now.difference(_startedAt);
        if (elapsed >= config.maxAckLag) {
          _triggerMandatoryStop('recorder_first_frame_unavailable');
          return false;
        }
      }
      return true;
    } catch (e) {
      if (e is FormatException) {
        if (e.message.contains('recorder_insecure_ingest')) {
          _triggerMandatoryStop('recorder_insecure_ingest');
          return false;
        }
        rethrow;
      }
      return _checkLeaseAndLag(now);
    }
  }

  bool _checkLeaseAndLag(DateTime now) {
    if (!config.mandatory) return true;
    final elapsed = now.difference(_startedAt);
    if ((config.requireFirstFrame || config.mandatory) && !_firstFrameAcked) {
      if (_desktopGraceUntil != null && now.isBefore(_desktopGraceUntil!)) {
        return true;
      }
      if (elapsed >= config.maxAckLag) {
        _triggerMandatoryStop('recorder_first_frame_unavailable');
        return false;
      }
      return true;
    }
    if (_leaseTtl != null && _leaseStopwatch.elapsed >= _leaseTtl!) {
      _triggerMandatoryStop('recorder_lease_expired');
      return false;
    }
    if (_lastAckAt != null && now.difference(_lastAckAt!) > config.maxAckLag) {
      _triggerMandatoryStop('recorder_ack_lag_exceeded');
      return false;
    }
    return true;
  }

  void _triggerMandatoryStop(String reason) {
    if (_stopped || (!config.mandatory && !config.requireFirstFrame)) return;
    _stopped = true;
    onMandatoryViolation?.call(reason);
  }
}
