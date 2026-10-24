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
  });

  final int ackHighWatermarkSeq;
  final bool firstFrameAcked;
  final DateTime leaseExpiresAt;
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
  })  : _clock = clock ?? DateTime.now,
        _startedAt = (clock ?? DateTime.now)().toUtc(),
        sendBatch = sendBatch ??
            ((batch) => _defaultHttpSendBatch(
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

  static Future<LinkRecorderBatchAck> _defaultHttpSendBatch(
    String ingestUrl,
    String ingestToken,
    Map<String, dynamic> batch,
  ) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final request = await client.postUrl(Uri.parse(ingestUrl));
      request.headers.contentType = ContentType.json;
      if (ingestToken.isNotEmpty) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $ingestToken');
      }
      request.add(utf8.encode(jsonEncode(batch)));
      final response = await request.close().timeout(const Duration(seconds: 10));
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('Recorder ingest status ${response.statusCode}');
      }
      final decoded = jsonDecode(body);
      if (decoded is! Map) {
        throw const FormatException('Invalid Recorder ACK JSON');
      }
      return LinkRecorderBatchAck(
        ackHighWatermarkSeq: (decoded['ack_high_watermark_seq'] as num?)?.toInt() ?? 0,
        firstFrameAcked: decoded['first_frame_acked'] == true,
        leaseExpiresAt: DateTime.tryParse(decoded['lease_expires_at']?.toString() ?? '') ??
            DateTime.now().toUtc().add(const Duration(seconds: 45)),
      );
    } finally {
      client.close(force: false);
    }
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

  final List<Map<String, dynamic>> _pendingFrames = [];
  final List<Map<String, dynamic>> _pendingEvents = [];
  Uint8List? _lastFramePayload;
  String? _lastMonitorId;
  int _queuedBytes = 0;
  int _nextSeq = 0;
  int _ackedSeq = 0;
  bool _firstFrameAcked = false;
  DateTime? _lastAckAt;
  DateTime? _leaseExpiresAt;
  Timer? _flushTimer;
  bool _stopped = false;
  Future<bool>? _activeFlush;

  int get nextSeq => _nextSeq;
  int get ackedSeq => _ackedSeq;
  bool get isFirstFrameAcked => !config.enabled || _firstFrameAcked;
  int get queuedBytes => _queuedBytes;

  void start() {
    _startedAt = _clock().toUtc();
    if (!config.enabled || _stopped || _flushTimer != null) return;
    if (_nextSeq == 0 && _pendingEvents.isEmpty) {
      _nextSeq++;
      _pendingEvents.add({
        'seq': _nextSeq,
        'event_type': 'session_started',
        'source': 'session_lifecycle',
        'occurred_at': _clock().toUtc().toIso8601String(),
        'metadata': {'mode': config.effectiveMode},
      });
    }
    _flushTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      unawaited(flushAndVerifyHealth());
    });
  }

  Future<void> stop({String reason = ''}) async {
    _flushTimer?.cancel();
    _flushTimer = null;
    while (_activeFlush != null) {
      try {
        await _activeFlush;
      } catch (_) {}
    }
    while (_pendingFrames.isNotEmpty || _pendingEvents.isNotEmpty) {
      final prevCount = _pendingFrames.length + _pendingEvents.length;
      final ok = await _flushInternal();
      final newCount = _pendingFrames.length + _pendingEvents.length;
      if (!ok || newCount >= prevCount) break;
    }
    _stopped = true;
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
            'key': rawKeyStr.trim(),
            if (rawCharStr.isNotEmpty) 'char': rawCharStr,
          },
        };
      case 'text_input':
        final text = raw['text']?.toString() ?? '';
        return {
          'event_type': 'text_input',
          'source': 'remote_operator',
          'occurred_at': occurredAt.toUtc().toIso8601String(),
          'metadata': {
            'text': text,
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
    _pendingEvents.add(sanitized);
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

    if (_pendingFrames.isEmpty && _pendingEvents.isEmpty) {
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
      'frames': List<Map<String, dynamic>>.from(_pendingFrames),
      'events': List<Map<String, dynamic>>.from(_pendingEvents),
    };

    try {
      final ack = await sendBatch(batch);
      _ackedSeq = ack.ackHighWatermarkSeq;
      if (ack.firstFrameAcked) {
        _firstFrameAcked = true;
      }
      _lastAckAt = _clock().toUtc();
      _leaseExpiresAt = ack.leaseExpiresAt.toUtc();

      // Удаляем только подтверждённые сервером элементы (seq <= ackHighWatermarkSeq),
      // чтобы не потерять события, упавшие в очередь во время HTTP-запроса (LR-03).
      _pendingFrames.removeWhere((f) => (f['seq'] as int) <= _ackedSeq);
      _pendingEvents.removeWhere((e) => (e['seq'] as int) <= _ackedSeq);

      _queuedBytes = _pendingFrames.fold<int>(0, (acc, f) {
        final b64 = f['payload_base64'] as String? ?? '';
        return acc + (b64.length * 3 ~/ 4);
      });

      if ((config.requireFirstFrame || config.mandatory) && !_firstFrameAcked) {
        final elapsed = now.difference(_startedAt);
        if (elapsed >= config.maxAckLag) {
          _triggerMandatoryStop('recorder_first_frame_unacked');
          return false;
        }
      }
      return true;
    } catch (_) {
      return _checkLeaseAndLag(now);
    }
  }

  bool _checkLeaseAndLag(DateTime now) {
    if (!config.mandatory) return true;
    final elapsed = now.difference(_startedAt);
    if ((config.requireFirstFrame || config.mandatory) && !_firstFrameAcked) {
      if (elapsed >= config.maxAckLag) {
        _triggerMandatoryStop('recorder_first_frame_unavailable');
        return false;
      }
      return true;
    }
    if (_leaseExpiresAt != null && !now.isBefore(_leaseExpiresAt!)) {
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
    if (_stopped) return;
    _stopped = true;
    onMandatoryViolation?.call(reason);
  }
}
