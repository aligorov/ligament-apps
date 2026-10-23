import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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
      requireFirstFrame: enabled && raw['require_first_frame'] == true,
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
    'home', 'end', 'pageup', 'pagedown',
    'arrowup', 'arrowdown', 'arrowleft', 'arrowright',
    'up', 'down', 'left', 'right',
    'f1', 'f2', 'f3', 'f4', 'f5', 'f6', 'f7', 'f8', 'f9', 'f10', 'f11', 'f12',
    'control', 'ctrl', 'alt', 'shift', 'meta', 'win', 'super',
  };

  final String sessionId;
  final LinkRecordingConfig config;
  final LinkRecorderBatchSender sendBatch;
  final void Function(String reason)? onMandatoryViolation;
  final DateTime Function() _clock;
  final DateTime _startedAt;

  final List<Map<String, dynamic>> _pendingFrames = [];
  final List<Map<String, dynamic>> _pendingEvents = [];
  int _queuedBytes = 0;
  int _nextSeq = 0;
  int _ackedSeq = 0;
  bool _firstFrameAcked = false;
  DateTime? _lastAckAt;
  DateTime? _leaseExpiresAt;
  Timer? _flushTimer;
  bool _stopped = false;

  int get nextSeq => _nextSeq;
  int get ackedSeq => _ackedSeq;
  bool get isFirstFrameAcked => !config.enabled || _firstFrameAcked;
  int get queuedBytes => _queuedBytes;

  void start() {
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
    if (_pendingFrames.isNotEmpty || _pendingEvents.isNotEmpty) {
      await flushAndVerifyHealth();
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
      case 'key_down':
      case 'key_up':
        final keyName = (raw['key']?.toString() ?? '').trim().toLowerCase();
        if (!_allowedNonPrintableKeys.contains(keyName)) {
          // Печатные символы и пароли никогда не сохраняются.
          return null;
        }
        return {
          'event_type': 'special_key',
          'source': 'remote_operator',
          'occurred_at': occurredAt.toUtc().toIso8601String(),
          'metadata': {'action': type, 'key': keyName},
        };
      case 'text_input':
        return {
          'event_type': 'text_input_redacted',
          'source': 'remote_operator',
          'occurred_at': occurredAt.toUtc().toIso8601String(),
          'metadata': {'redacted': true},
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

  /// Добавляет кадр в ограниченную очередь (Инвариант 7, 8, 9).
  bool enqueueFrame({
    required String frameKind,
    required Uint8List payload,
    String monitorId = 'primary',
    int width = 1920,
    int height = 1080,
    String codec = 'webp',
  }) {
    if (!config.enabled || _stopped) return true;
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
    final now = _clock().toUtc();

    if (_pendingFrames.isEmpty && _pendingEvents.isEmpty) {
      return _checkLeaseAndLag(now);
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
      _pendingFrames.clear();
      _pendingEvents.clear();
      _queuedBytes = 0;

      if (config.requireFirstFrame && !_firstFrameAcked) {
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
    if (config.requireFirstFrame && !_firstFrameAcked) {
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
