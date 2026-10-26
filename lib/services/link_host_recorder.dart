import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'debug_log_service.dart';
import 'link_spool_storage.dart';

void _recorderLog(String event,
        {Object? error, Map<String, Object?> fields = const {}}) =>
    DebugLogService.instance.record(event, error: error, fields: fields);

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
    final width =
        (bytes[16] << 24) | (bytes[17] << 16) | (bytes[18] << 8) | bytes[19];
    final height =
        (bytes[20] << 24) | (bytes[21] << 16) | (bytes[22] << 8) | bytes[23];
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

      if (marker == 0xD8 ||
          marker == 0xD9 ||
          (marker >= 0xD0 && marker <= 0xD7)) {
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
    if (bytes[12] == 0x56 &&
        bytes[13] == 0x50 &&
        bytes[14] == 0x38 &&
        bytes[15] == 0x20) {
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
    if (bytes[12] == 0x56 &&
        bytes[13] == 0x50 &&
        bytes[14] == 0x38 &&
        bytes[15] == 0x4C) {
      if (bytes.length >= 25 && bytes[20] == 0x2F) {
        final b1 = bytes[21];
        final b2 = bytes[22];
        final b3 = bytes[23];
        final b4 = bytes[24];
        final width = 1 + (((b2 & 0x3F) << 8) | b1);
        final height =
            1 + (((b4 & 0xF) << 10) | (b3 << 2) | ((b2 & 0xC0) >> 6));
        return RecordedFrameInfo(
          payload: bytes,
          width: width,
          height: height,
          codec: 'webp',
        );
      }
    }
    if (bytes[12] == 0x56 &&
        bytes[13] == 0x50 &&
        bytes[14] == 0x38 &&
        bytes[15] == 0x58) {
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
    _recorderLog('recorder.exception',
        error: e,
        fields: {'phase': 'prepare_recorded_frame', 'result': 'failed'});
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
    this.maxQueueBytes = 64 * 1024 * 1024,
    this.failurePolicy = 'strict',
    this.spoolEnabled = false,
    this.maxSpoolBytes = 1024 * 1024 * 1024,
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
  final String failurePolicy; // resilient, strict
  final bool spoolEnabled;
  final int maxSpoolBytes;

  bool get isActive =>
      enabled && effectiveMode != 'exclude' && ingestUrl.isNotEmpty;

  bool get isStrict => mandatory && failurePolicy == 'strict';

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
    final failurePolicy = raw['failure_policy'] is String
        ? (raw['failure_policy'] as String).trim().toLowerCase()
        : 'resilient';
    final spoolEnabled = raw['spool_enabled'] != false;
    final maxSpoolBytes = raw['max_spool_bytes'] is int
        ? raw['max_spool_bytes'] as int
        : 1024 * 1024 * 1024;
    return LinkRecordingConfig(
      contractVersion: raw['contract_version']?.toString() ?? 'v1',
      enabled: enabled && mode != 'exclude',
      mandatory: enabled && mandatory && mode != 'exclude',
      requireFirstFrame:
          enabled && (raw['require_first_frame'] == true || mandatory),
      effectiveMode: mode,
      aiAllowed: raw['ai_allowed'] == true && mode == 'record+AI',
      policyReason: raw['policy_reason']?.toString() ?? '',
      ingestUrl: raw['ingest_url']?.toString() ?? '',
      ingestToken: raw['ingest_token']?.toString() ?? '',
      epoch: raw['epoch'] is int ? (raw['epoch'] as int) : 1,
      leaseTtl: Duration(seconds: leaseSec),
      maxAckLag: Duration(seconds: lagSec),
      failurePolicy: failurePolicy,
      spoolEnabled: spoolEnabled,
      maxSpoolBytes: maxSpoolBytes,
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

/// HTTP failure facts only; response text, tokens and query strings are excluded.
class LinkRecorderHttpException implements Exception {
  const LinkRecorderHttpException({
    required this.statusCode,
    required this.code,
    required this.server,
    required this.route,
    required this.requestId,
  });

  final int statusCode;
  final String code;
  final String server;
  final String route;
  final int requestId;
  String get method => 'POST';

  @override
  String toString() =>
      'Recorder HTTP $statusCode ($code), $method $server$route';
}

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
    LinkSpoolStorage? spool,
    DateTime Function()? clock,
    Stopwatch? leaseStopwatch,
    Duration? stopFlushTimeout,
    DebugLogService? debugLog,
  })  : _debugLog = debugLog ?? DebugLogService.instance,
        spool = spool ??
            (config.spoolEnabled
                ? LinkSpoolStorage(
                    sessionId: sessionId,
                    maxSpoolBytes: config.maxSpoolBytes,
                    debugLog: debugLog,
                  )
                : null),
        _clock = clock ?? DateTime.now,
        _startedAt = (clock ?? DateTime.now)().toUtc(),
        _leaseStopwatch = leaseStopwatch ?? Stopwatch(),
        _stopFlushTimeout = stopFlushTimeout ?? const Duration(seconds: 25),
        sendBatch = sendBatch ??
            ((batch) => defaultHttpSendBatch(
                  config.ingestUrl,
                  config.ingestToken,
                  batch,
                  debugLog: debugLog,
                )) {
    if (sessionId.toLowerCase().startsWith('link_')) {
      throw const FormatException(
        'Temporary link_<agentId> identifier is forbidden for Recorder archive',
      );
    }
  }

  final LinkSpoolStorage? spool;
  int _spoolBatchIndex = 0;

  bool get isThrottled => _queuedBytes >= (config.maxQueueBytes ~/ 2);

  static HttpClient? _sharedHttpClient;

  static HttpClient _getSharedClient() {
    return _sharedHttpClient ??=
        (HttpClient()..connectionTimeout = const Duration(seconds: 8));
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
        try {
          final body = utf8.decode(bytes);
          finish(() => completer.complete(body));
        } catch (error, stackTrace) {
          finish(() => completer.completeError(error, stackTrace));
        }
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
    DebugLogService? debugLog,
  }) async {
    final log = debugLog ?? DebugLogService.instance;
    final uri = Uri.tryParse(ingestUrl);
    if (!isSecureIngestUri(uri)) {
      log.record('recorder.http.blocked',
          fields: {'reason': 'insecure_ingest', 'result': 'blocked'});
      throw const FormatException('recorder_insecure_ingest');
    }
    final destination = uri!;
    final server =
        '${destination.host.contains(':') ? '[${destination.host}]' : destination.host}:${destination.port}';
    final path = destination.path;
    final route =
        RegExp(r'^/api/v1/link/sessions/[^/]+/recorder/batch$').hasMatch(path)
            ? '/api/v1/link/sessions/{id}/recorder/batch'
            : RegExp(r'^/api/v1/ingest/sessions/[^/]+/batch$').hasMatch(path)
                ? '/api/v1/ingest/sessions/{id}/batch'
                : '/{recorder_ingest}';
    final requestId = log.nextRequestId();
    final watch = Stopwatch()..start();
    var phase = 'request_open';
    var sentBytes = 0;
    var responseBytes = 0;
    int? status;
    HttpClientRequest? request;
    var openExpired = false;
    Duration remaining() {
      final time = timeout - watch.elapsed;
      if (time <= Duration.zero) {
        throw TimeoutException('Recorder HTTP operation timeout', timeout);
      }
      return time;
    }

    void diagnostic(String event, String result,
        {Object? error, String? code}) {
      log.record(event, error: error, fields: {
        'request_id': requestId,
        'method': 'POST',
        'server': server,
        'route': route,
        'phase': phase,
        if (status != null) 'http_status': status,
        'duration_ms': watch.elapsedMilliseconds,
        'sent_bytes': sentBytes,
        'response_bytes': responseBytes,
        if (code != null) 'reason': DebugLogService.protocolLabel(code),
        'result': result,
      });
    }

    diagnostic('recorder.http', 'begin');
    try {
      final encoded = utf8.encode(jsonEncode(batch));
      final httpClient = client ?? _getSharedClient();
      request = await httpClient.postUrl(destination).then((opened) {
        if (openExpired) opened.abort();
        return opened;
      }).timeout(remaining(), onTimeout: () {
        openExpired = true;
        throw TimeoutException('Recorder request open timeout', timeout);
      });
      // Do not forward the ingest bearer token to a redirected destination.
      request.followRedirects = false;
      request.headers.contentType = ContentType.json;
      if (ingestToken.isNotEmpty) {
        request.headers
            .set(HttpHeaders.authorizationHeader, 'Bearer $ingestToken');
      }
      request.add(encoded);
      sentBytes = encoded.length;
      phase = 'response_wait';
      diagnostic('recorder.http', 'queued');
      final response = await request.close().timeout(remaining());
      status = response.statusCode;
      phase = 'ack_read';
      diagnostic('recorder.http', 'response');
      final body = await _readAckBody(response, remaining());
      responseBytes = utf8.encode(body).length;
      diagnostic('recorder.http', 'received');
      phase = 'ack_validate';
      if (status < 200 || status >= 300) {
        String code = 'unknown';
        try {
          final errorBody = jsonDecode(body);
          if (errorBody is Map) {
            code = DebugLogService.protocolLabel(
                errorBody['code'] ?? errorBody['error']);
          }
        } on FormatException {
          // Non-JSON errors still retain HTTP facts, never the response text.
        }
        throw LinkRecorderHttpException(
          statusCode: status,
          code: code,
          server: server,
          route: route,
          requestId: requestId,
        );
      }
      final decoded = jsonDecode(body);
      if (decoded is! Map) {
        throw const FormatException('Invalid Recorder ACK JSON');
      }
      if (decoded['ack_high_watermark_seq'] == null ||
          decoded['ack_high_watermark_seq'] is! num) {
        throw const FormatException(
            'Recorder ACK missing required ack_high_watermark_seq');
      }
      if (decoded['lease_expires_at'] == null) {
        throw const FormatException(
            'Recorder ACK missing required lease_expires_at');
      }
      final leaseExpiresAt =
          DateTime.tryParse(decoded['lease_expires_at']?.toString() ?? '');
      if (leaseExpiresAt == null) {
        throw const FormatException('Recorder ACK invalid lease_expires_at');
      }
      final leaseTtlMs = decoded['lease_ttl_ms'] is num
          ? (decoded['lease_ttl_ms'] as num).toInt()
          : null;
      diagnostic('recorder.http', 'validated');
      return LinkRecorderBatchAck(
        ackHighWatermarkSeq: (decoded['ack_high_watermark_seq'] as num).toInt(),
        firstFrameAcked: decoded['first_frame_acked'] == true,
        leaseExpiresAt: leaseExpiresAt,
        leaseTtlMs: leaseTtlMs,
      );
    } catch (error) {
      request?.abort();
      diagnostic('recorder.http.failed', 'failed',
          error: error,
          code: error is LinkRecorderHttpException ? error.code : null);
      rethrow;
    }
  }

  static const Set<String> _allowedNonPrintableKeys = {
    'enter',
    'return',
    'tab',
    'escape',
    'esc',
    'backspace',
    'delete',
    'insert',
    'home',
    'end',
    'pageup',
    'page up',
    'pagedown',
    'page down',
    'arrowup',
    'arrow up',
    'arrowdown',
    'arrow down',
    'arrowleft',
    'arrow left',
    'arrowright',
    'arrow right',
    'up',
    'down',
    'left',
    'right',
    'space',
    'capslock',
    'caps lock',
    'numlock',
    'num lock',
    'scrolllock',
    'scroll lock',
    'f1',
    'f2',
    'f3',
    'f4',
    'f5',
    'f6',
    'f7',
    'f8',
    'f9',
    'f10',
    'f11',
    'f12',
    'control',
    'ctrl',
    'control left',
    'control right',
    'ctrl left',
    'ctrl right',
    'alt',
    'alt left',
    'alt right',
    'shift',
    'shift left',
    'shift right',
    'meta',
    'meta left',
    'meta right',
    'win',
    'super',
  };

  final String sessionId;
  final LinkRecordingConfig config;
  final LinkRecorderBatchSender sendBatch;
  final void Function(String reason)? onMandatoryViolation;
  final DateTime Function() _clock;
  final DebugLogService _debugLog;
  DateTime _startedAt;

  static const int maxBatchBytes = 2 * 1024 * 1024;
  static const int maxBatchFrames = 20;
  static const int maxBatchEvents = 200;
  static const int _maxFrameBytes = 8 * 1024 * 1024;
  static const int _maxMetadataBytes = 16 * 1024;
  static const int _maxQueuedFrames = 1024;
  static const int _maxQueuedEvents = 4096;
  static const int _maxFlushBatches = 128;
  // Reserve a coverage frame marker, loss counters and lifecycle events.
  static const int _queueControlReserveBytes = 1024;
  static const int _maxLossCount = 0x7fffffffffffffff;

  final List<Map<String, dynamic>> _pendingFrames = [];
  final List<Map<String, dynamic>> _pendingEvents = [];
  Uint8List? _lastFramePayload;
  String? _lastMonitorId;
  int _queuedBytes = 0;
  int _nextSeq = 0;
  int _ackedSeq = 0;
  bool _firstFrameAcked = false;
  DateTime? _lastAckAt;
  DateTime? _noProgressSince;
  final Stopwatch _leaseStopwatch;
  Duration? _leaseTtl;
  DateTime? _desktopGraceUntil;
  Timer? _flushTimer;
  bool _stopped = false;
  bool _sessionEndedRecorded = false;
  bool _tailFlushed = true;
  Future<bool>? _activeFlush;
  Future<bool>? _activeStop;
  Stopwatch? _stopWatch;
  Map<String, dynamic>? _gapMarker;
  bool _gapMarkerFrozen = false;
  int _droppedFrames = 0;
  int _droppedEvents = 0;

  void _snapshot(String event,
      {Object? error, Map<String, Object?> fields = const {}}) {
    _debugLog.record(event, error: error, fields: {
      'session_id': sessionId,
      'recorder_enabled': config.enabled,
      'mandatory': config.mandatory,
      'seq': _nextSeq,
      'acked_seq': _ackedSeq,
      'queue_bytes': _queuedBytes,
      'frames': _pendingFrames.length,
      'count': _pendingEvents.length,
      'first_frame_acked': _firstFrameAcked,
      'state': _stopped ? 'stopped' : 'running',
      ...fields,
      if (fields.containsKey('reason'))
        'reason': DebugLogService.protocolLabel(fields['reason']),
    });
  }

  int get nextSeq => _nextSeq;
  int get ackedSeq => _ackedSeq;
  bool get isFirstFrameAcked => !config.enabled || _firstFrameAcked;
  bool get firstFrameAcked => _firstFrameAcked;
  bool get isTailFlushed =>
      _tailFlushed &&
      _pendingFrames.isEmpty &&
      _pendingEvents.isEmpty &&
      _droppedFrames == 0 &&
      _droppedEvents == 0 &&
      (spool == null || !spool!.hasPendingChunks);
  int get queuedBytes => _queuedBytes;

  void notifyDesktopChanged() {
    _snapshot('recorder.desktop.changed', fields: {'timeout_ms': 10000});
    final now = _clock().toUtc();
    // Льготный период при смене рабочего стола (≤ 10 с, без продления, пока он активен)
    if (_desktopGraceUntil == null || now.isAfter(_desktopGraceUntil!)) {
      _desktopGraceUntil = now.add(const Duration(seconds: 10));
    }
  }

  void start() {
    _snapshot('recorder.start', fields: {
      'result': !config.enabled || _stopped || _flushTimer != null
          ? 'ignored'
          : 'begin'
    });
    if (!config.enabled || _stopped || _flushTimer != null) return;
    _startedAt = _clock().toUtc();

    if (config.ingestUrl.isNotEmpty &&
        (config.mandatory || config.requireFirstFrame)) {
      final uri = Uri.tryParse(config.ingestUrl);
      if (!isSecureIngestUri(uri)) {
        _triggerMandatoryStop('recorder_insecure_ingest');
        return;
      }
    }

    if (_nextSeq == 0 && _pendingEvents.isEmpty) {
      _appendLifecycle('session_started', {'mode': config.effectiveMode});
    }
    _flushTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      unawaited(flushAndVerifyHealth().catchError((Object error) {
        _snapshot('recorder.flush.failed',
            error: error, fields: {'result': 'failed'});
        return _checkLeaseAndLag(_clock().toUtc());
      }));
    });
  }

  final Duration _stopFlushTimeout;

  Future<bool> stop({String reason = ''}) async {
    if (_activeStop != null) return await _activeStop!;
    final stopping = _stop(reason);
    _activeStop = stopping;
    try {
      return await stopping;
    } finally {
      _activeStop = null;
    }
  }

  Duration _remainingStopTime() {
    final remaining = _stopFlushTimeout - _stopWatch!.elapsed;
    if (remaining <= Duration.zero) {
      throw TimeoutException('Recorder stop deadline', _stopFlushTimeout);
    }
    return remaining;
  }

  Future<bool> _stop(String reason) async {
    _stopWatch = Stopwatch()..start();
    _stopped = true;
    _flushTimer?.cancel();
    _flushTimer = null;
    _snapshot('recorder.stop', fields: {
      'reason': reason,
      'result': 'begin',
      'timeout_ms': _stopFlushTimeout.inMilliseconds
    });
    if (!config.enabled) return true;
    try {
      if (_activeSpill != null) {
        try {
          await _activeSpill!.timeout(_remainingStopTime());
        } catch (_) {}
      }
      // The same budget covers an already-running cycle and every tail batch.
      if (_activeFlush != null) {
        try {
          await _activeFlush!.timeout(_remainingStopTime());
        } on TimeoutException {
          rethrow;
        } catch (error) {
          _snapshot('recorder.stop.flush_failed',
              error: error,
              fields: {'phase': 'active_flush', 'result': 'retry'});
        }
      }
      if (!_sessionEndedRecorded) {
        final isViolation = reason.isNotEmpty &&
            reason != 'normal' &&
            reason != 'user_disconnected' &&
            reason != 'session_ended';
        final label = reason.isNotEmpty ? reason : 'normal';
        _sessionEndedRecorded = _appendLifecycle(
          isViolation ? 'mandatory_violation' : 'session_ended',
          {'reason': label, if (isViolation) 'violation': label},
        );
      }
      while (_pendingFrames.isNotEmpty ||
          _pendingEvents.isNotEmpty ||
          _droppedFrames > 0 ||
          _droppedEvents > 0) {
        final before = _pendingFrames.length + _pendingEvents.length;
        final ok = await _serializedFlush().timeout(_remainingStopTime());
        final after = _pendingFrames.length + _pendingEvents.length;
        if (!ok || after >= before) break;
      }
    } on TimeoutException catch (error) {
      _snapshot('recorder.stop.timeout', error: error, fields: {
        'phase': 'tail_flush',
        'result': 'failed',
        'timeout_ms': _stopFlushTimeout.inMilliseconds
      });
    } catch (error) {
      _snapshot('recorder.stop.failed',
          error: error, fields: {'phase': 'tail_flush', 'result': 'failed'});
    }
    // Never replace or clear unconfirmed data, even on timeout. A late ACK may
    // still remove only its own snapshot; subsequent stop() may retry the tail.
    _tailFlushed = _sessionEndedRecorded &&
        _pendingFrames.isEmpty &&
        _pendingEvents.isEmpty &&
        _droppedFrames == 0 &&
        _droppedEvents == 0 &&
        (spool == null || !spool!.hasPendingChunks);
    _snapshot('recorder.stop',
        fields: {'result': isTailFlushed ? 'tail_flushed' : 'tail_lost'});
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
            'direction': type == 'clipboard_set'
                ? 'operator_to_host'
                : 'host_to_operator',
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

  static int _jsonBytes(Object value) => utf8.encode(jsonEncode(value)).length;

  void _recalculateQueuedBytes() {
    _queuedBytes =
        _pendingFrames.fold<int>(0, (sum, f) => sum + _jsonBytes(f)) +
            _pendingEvents.fold<int>(0, (sum, e) => sum + _jsonBytes(e));
  }

  bool _appendLifecycle(String type, Map<String, dynamic> metadata) {
    final event = {
      'seq': _nextSeq + 1,
      'event_type': type,
      'source': 'session_lifecycle',
      'occurred_at': _clock().toUtc().toIso8601String(),
      'metadata': metadata,
    };
    final bytes = _jsonBytes(event);
    if (bytes > _maxMetadataBytes ||
        _queuedBytes + bytes > config.maxQueueBytes ||
        _pendingEvents.length >= _maxQueuedEvents + 3) {
      _recordDrop(isFrame: false, bytes: bytes);
      return false;
    }
    _nextSeq++;
    _pendingEvents.add(event);
    _queuedBytes += bytes;
    return true;
  }

  void _recordDrop({required bool isFrame, required int bytes}) {
    if (isFrame) {
      _droppedFrames = (_droppedFrames + 1).clamp(0, _maxLossCount);
    } else {
      _droppedEvents = (_droppedEvents + 1).clamp(0, _maxLossCount);
    }
    _materializeLossMarker();
    _snapshot('recorder.queue.overflow',
        fields: {'bytes': bytes, 'result': 'dropped'});
    if (config.mandatory) {
      if (config.isStrict) {
        _triggerMandatoryStop('recorder_queue_overflow');
      } else {
        unawaited(_spillToSpool());
      }
    }
  }

  Future<void>? _activeSpill;

  Future<void> _spillToSpool() {
    if (_activeSpill != null) return _activeSpill!;
    if (_stopped || spool == null) return Future.value();
    final spilling = _doSpillToSpool();
    _activeSpill = spilling;
    return spilling.whenComplete(() => _activeSpill = null);
  }

  Future<void> _doSpillToSpool() async {
    try {
      while (_pendingFrames.isNotEmpty || _pendingEvents.isNotEmpty) {
        final batchFrames = <Map<String, dynamic>>[];
        final batchEvents = <Map<String, dynamic>>[];
        var spilledBytes = 0;

        while (_pendingFrames.isNotEmpty && batchFrames.length < maxBatchFrames) {
          final frame = _pendingFrames.removeAt(0);
          batchFrames.add(frame);
          spilledBytes += _jsonBytes(frame);
        }
        while (_pendingEvents.isNotEmpty && batchEvents.length < maxBatchEvents) {
          final event = _pendingEvents.removeAt(0);
          batchEvents.add(event);
          spilledBytes += _jsonBytes(event);
        }

        if (batchFrames.isEmpty && batchEvents.isEmpty) break;
        _queuedBytes = (_queuedBytes - spilledBytes).clamp(0, 0x7fffffffffffffff);

        final batch = {
          'session_id': sessionId,
          'epoch': config.epoch,
          'lease_ttl_seconds': config.leaseTtl.inSeconds,
          'frames': batchFrames,
          'events': batchEvents,
        };

        await spool!.writeBatch(++_spoolBatchIndex, batch);
        _snapshot('recorder.spool.buffered', fields: {
          'batch_index': _spoolBatchIndex,
          'frames': batchFrames.length,
          'events': batchEvents.length,
          'spilled_bytes': spilledBytes,
        });

        // Сбрасываем до нижнего порога гистерезиса (25% от maxQueueBytes)
        if (_queuedBytes <= (config.maxQueueBytes ~/ 4)) break;
      }
    } on LinkSpoolQuotaExceededException catch (error) {
      _snapshot('recorder.spool.quota_exceeded', error: error);
      _triggerMandatoryStop('recorder_spool_quota_exceeded');
    } catch (error) {
      _snapshot('recorder.spool.failed', error: error);
    }
  }

  void _materializeLossMarker() {
    if ((_droppedFrames == 0 && _droppedEvents == 0) ||
        (_gapMarker != null && _gapMarkerFrozen)) {
      return;
    }
    final previous = _gapMarker;
    final previousMetadata = previous?['metadata'] as Map?;
    final frameMarker = previous == null
        ? <String, dynamic>{
            'seq': _nextSeq + 1,
            'frame_kind': 'gap_marker',
            'monitor_id': 'primary',
            'width': 0,
            'height': 0,
            'codec': 'png',
            'payload_base64': '',
            'captured_at': _clock().toUtc().toIso8601String(),
          }
        : null;
    final marker = <String, dynamic>{
      'seq': previous?['seq'] ?? _nextSeq + 2,
      'event_type': 'gap_marker',
      'source': 'session_lifecycle',
      'occurred_at':
          previous?['occurred_at'] ?? _clock().toUtc().toIso8601String(),
      'metadata': {
        'reason': 'recorder_queue_overflow',
        'dropped_frames': ((_droppedFrames +
                ((previousMetadata?['dropped_frames'] as int?) ?? 0)))
            .clamp(0, _maxLossCount),
        'dropped_events': ((_droppedEvents +
                ((previousMetadata?['dropped_events'] as int?) ?? 0)))
            .clamp(0, _maxLossCount),
      },
    };
    final delta = _jsonBytes(marker) -
        (previous == null ? 0 : _jsonBytes(previous)) +
        (frameMarker == null ? 0 : _jsonBytes(frameMarker));
    if (_queuedBytes + delta > config.maxQueueBytes ||
        (previous == null &&
            (_pendingEvents.length >= _maxQueuedEvents + 3 ||
                _pendingFrames.length >= _maxQueuedFrames + 1))) {
      return;
    }
    if (previous == null) {
      _nextSeq += 2;
      _pendingFrames.add(frameMarker!);
      _gapMarker = marker;
      _gapMarkerFrozen = false;
      _pendingEvents.add(marker);
    } else {
      // Only a never-sent marker may be updated. Failed/partial sends freeze it
      // until durable ACK; later loss stays in bounded counters, not new items.
      previous['metadata'] = marker['metadata'];
    }
    _queuedBytes += delta;
    _droppedFrames = 0;
    _droppedEvents = 0;
  }

  bool _fitsDataQueue(int bytes) =>
      _queuedBytes + bytes <= config.maxQueueBytes - _queueControlReserveBytes;

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
        (_bytesEqual(_lastFramePayload!, payload) || isThrottled)) {
      // Экран находится в состоянии покоя (простой) или активен троттлинг очереди — не засоряем архив избыточными кадрами.
      return true;
    }
    final frame = <String, dynamic>{
      'seq': _nextSeq + 1,
      'frame_kind': frameKind,
      'monitor_id': monitorId,
      'width': width,
      'height': height,
      'codec': codec,
      'payload_base64': '',
      'captured_at': _clock().toUtc().toIso8601String(),
    };
    final metadataBytes = _jsonBytes(frame);
    final encodedBytes = metadataBytes + ((payload.length + 2) ~/ 3) * 4;
    if (payload.length > _maxFrameBytes ||
        metadataBytes > _maxMetadataBytes ||
        !_fitsDataQueue(encodedBytes) ||
        _pendingFrames.length >= _maxQueuedFrames ||
        (encodedBytes > maxBatchBytes &&
            !const {'jpeg', 'png', 'webp'}.contains(codec))) {
      _recordDrop(isFrame: true, bytes: encodedBytes);
      return false;
    }
    frame['payload_base64'] = base64Encode(payload);
    _lastFramePayload = Uint8List.fromList(payload);
    _lastMonitorId = monitorId;
    _nextSeq++;
    _queuedBytes += encodedBytes;
    _pendingFrames.add(frame);
    return true;
  }

  /// Фильтрует и ставит событие ввода в очередь записи.
  void observeControlInput(Map<String, dynamic> rawInput) {
    if (!config.enabled || _stopped) return;
    final sanitized = sanitizeInputEvent(rawInput, occurredAt: _clock());
    if (sanitized == null) return;
    sanitized['seq'] = _nextSeq + 1;
    String encoded;
    try {
      encoded = jsonEncode(sanitized);
    } on JsonUnsupportedObjectError {
      _recordDrop(isFrame: false, bytes: 0);
      return;
    }
    final eventBytes = utf8.encode(encoded).length;
    if (eventBytes > _maxMetadataBytes ||
        !_fitsDataQueue(eventBytes) ||
        _pendingEvents.length >= _maxQueuedEvents) {
      _recordDrop(isFrame: false, bytes: eventBytes);
      return;
    }
    _nextSeq++;
    // Detach any metadata values originating from the caller's mutable input.
    _pendingEvents.add(jsonDecode(encoded) as Map<String, dynamic>);
    _queuedBytes += eventBytes;
  }

  /// Отправляет накопленный пакет в Recorder и проверяет долговечный ACK (Инвариант 1, 2, 5).
  Future<bool> flushAndVerifyHealth() async {
    if (!config.enabled || _stopped) return true;
    return await _serializedFlush();
  }

  Future<bool> _serializedFlush() async {
    if (_activeFlush != null) return await _activeFlush!;
    final f = _flushCycle();
    _activeFlush = f;
    try {
      return await f;
    } finally {
      _activeFlush = null;
    }
  }

  int _snapshotCount(int upperSeq) =>
      _pendingFrames.where((f) => (f['seq'] as int) <= upperSeq).length +
      _pendingEvents.where((e) => (e['seq'] as int) <= upperSeq).length;

  Future<bool> _flushCycle() async {
    if (_activeSpill != null) {
      await _activeSpill;
    }
    _materializeLossMarker();
    final upperSeq = _nextSeq;
    // Freeze the complete cycle snapshot, including markers not yet selected.
    if (_gapMarker != null) _gapMarkerFrozen = true;
    for (var i = 0; i < _maxFlushBatches; i++) {
      if (_stopWatch != null && _stopWatch!.elapsed >= _stopFlushTimeout) {
        return false;
      }
      final before = _snapshotCount(upperSeq);
      final ok = await _flushInternal(upperSeq);
      if (!ok) return false;
      final after = _snapshotCount(upperSeq);
      if (after < before) _noProgressSince = null;
      final hasSpooledChunks = spool != null && spool!.hasPendingChunks;
      if (!hasSpooledChunks && (before == 0 || after == 0 || after >= before)) {
        if (before > 0 && after >= before) {
          _noProgressSince ??= _clock().toUtc();
          _snapshot('recorder.batch.no_progress', fields: {'result': 'retry'});
          return _checkLeaseAndLag(_clock().toUtc());
        }
        return true;
      }
    }
    _snapshot('recorder.flush.capped',
        fields: {'count': _maxFlushBatches, 'result': 'retry'});
    return true;
  }

  Future<bool> _flushInternal(int upperSeq) async {
    final now = _clock().toUtc();

    if (config.ingestUrl.isNotEmpty &&
        (config.mandatory || config.requireFirstFrame)) {
      final uri = Uri.tryParse(config.ingestUrl);
      if (uri == null || !isSecureIngestUri(uri)) {
        _triggerMandatoryStop('recorder_insecure_ingest');
        return false;
      }
    }

    if (spool != null && spool!.hasPendingChunks) {
      final pendingFiles = await spool!.getPendingBatches();
      for (final file in pendingFiles) {
        final spooledBatch = await spool!.readBatch(file);
        if (spooledBatch != null) {
          try {
            final ack = await sendBatch(spooledBatch);
            await spool!.removeBatch(file);
            _snapshot('recorder.spool.drained', fields: {'file': file.path});

            // Обновляем Lease и ACK состояние на основе ответа на батч спула
            final ackNow = _clock().toUtc();
            _lastAckAt = ackNow;
            if (ack.leaseTtlMs != null && ack.leaseTtlMs! > 0) {
              _leaseTtl = Duration(milliseconds: ack.leaseTtlMs!);
            } else if (ack.leaseExpiresAt.isAfter(ackNow)) {
              _leaseTtl = ack.leaseExpiresAt.difference(ackNow);
            }
            _leaseStopwatch.reset();
            _leaseStopwatch.start();
            if (ack.ackHighWatermarkSeq > _ackedSeq) {
              _ackedSeq = ack.ackHighWatermarkSeq;
            }
            _firstFrameAcked = true;
          } catch (error) {
            _snapshot('recorder.spool.drain_retry', error: error);
            // Прерываем флаш: нельзя отправлять свежие кадры из памяти вперед старых со спула.
            // Статус здоровья определяется допустимым лагом и арендой.
            return _checkLeaseAndLag(now);
          }
        } else {
          await spool!.removeBatch(file);
        }
        // Отправляем максимум 1 батч спула за цикл флаша, чтобы не забивать WebRTC полосу
        break;
      }
    }

    final batchFrames = <Map<String, dynamic>>[];
    final batchEvents = <Map<String, dynamic>>[];
    final batch = {
      'session_id': sessionId,
      'epoch': config.epoch,
      'lease_ttl_seconds': config.leaseTtl.inSeconds,
      'frames': batchFrames,
      'events': batchEvents,
    };
    var currentBatchBytes = _jsonBytes(batch);
    var frameIndex = 0;
    var eventIndex = 0;
    while (true) {
      final frame = frameIndex < _pendingFrames.length &&
              (_pendingFrames[frameIndex]['seq'] as int) <= upperSeq
          ? _pendingFrames[frameIndex]
          : null;
      final event = eventIndex < _pendingEvents.length &&
              (_pendingEvents[eventIndex]['seq'] as int) <= upperSeq
          ? _pendingEvents[eventIndex]
          : null;
      if (frame == null && event == null) break;
      final isFrame = frame != null &&
          (event == null || (frame['seq'] as int) < (event['seq'] as int));
      final item = isFrame ? frame : event;
      final selected = isFrame ? batchFrames : batchEvents;
      if (selected.length >= (isFrame ? maxBatchFrames : maxBatchEvents)) break;
      final nextBytes =
          currentBatchBytes + _jsonBytes(item!) + (selected.isEmpty ? 0 : 1);
      if (nextBytes > maxBatchBytes) {
        // The Core 20 MiB proxy can carry one supported <=8 MiB raw frame.
        // Never append events or other frames to that exceptional batch.
        if (batchFrames.isEmpty &&
            batchEvents.isEmpty &&
            isFrame &&
            const {'jpeg', 'png', 'webp'}.contains(item['codec']) &&
            nextBytes <= 20 * 1024 * 1024) {
          selected.add(item);
          currentBatchBytes = nextBytes;
        }
        break;
      }
      selected.add(item);
      currentBatchBytes = nextBytes;
      if (isFrame) {
        frameIndex++;
      } else {
        eventIndex++;
      }
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

    final inFlightFrameSeqs = batchFrames.map((f) => f['seq'] as int).toSet();
    final inFlightEventSeqs = batchEvents.map((e) => e['seq'] as int).toSet();

    final sendStopwatch = Stopwatch()..start();
    _snapshot('recorder.batch.send', fields: {
      'result': 'begin',
      'bytes': currentBatchBytes,
      'frames': batchFrames.length,
      'count': batchEvents.length
    });
    try {
      final ack = await sendBatch(batch);
      sendStopwatch.stop();
      final rtt = sendStopwatch.elapsed;
      _snapshot('recorder.batch.ack_received', fields: {
        'acked_seq': ack.ackHighWatermarkSeq,
        'first_frame_acked': ack.firstFrameAcked,
        'rtt_ms': rtt.inMilliseconds,
        'result': 'received'
      });

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
        throw const FormatException(
            'Recorder ACK missing required lease_ttl_ms in mandatory mode');
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
      _pendingFrames.removeWhere((f) =>
          inFlightFrameSeqs.contains(f['seq'] as int) &&
          (f['seq'] as int) <= _ackedSeq);
      _pendingEvents.removeWhere((e) =>
          inFlightEventSeqs.contains(e['seq'] as int) &&
          (e['seq'] as int) <= _ackedSeq);

      if (_gapMarker != null && !_pendingEvents.contains(_gapMarker)) {
        _gapMarker = null;
        _gapMarkerFrozen = false;
      }
      _recalculateQueuedBytes();
      _materializeLossMarker();
      _snapshot('recorder.batch.ack_validated',
          fields: {'rtt_ms': rtt.inMilliseconds, 'result': 'validated'});

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
      _snapshot('recorder.batch.failed', error: e, fields: {
        'duration_ms': sendStopwatch.elapsedMilliseconds,
        'bytes': currentBatchBytes,
        'frames': batchFrames.length,
        'count': batchEvents.length,
        if (e is LinkRecorderHttpException) ...{
          'request_id': e.requestId,
          'method': e.method,
          'server': e.server,
          'route': e.route,
          'http_status': e.statusCode,
          'reason': e.code,
        },
        'result': 'failed'
      });
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
    if ((_lastAckAt != null &&
            now.difference(_lastAckAt!) > config.maxAckLag) ||
        (_noProgressSince != null &&
            now.difference(_noProgressSince!) >= config.maxAckLag)) {
      _triggerMandatoryStop('recorder_ack_lag_exceeded');
      return false;
    }
    return true;
  }

  void _triggerMandatoryStop(String reason) {
    if (_stopped || (!config.mandatory && !config.requireFirstFrame)) return;
    if (!config.isStrict &&
        (reason == 'recorder_queue_overflow' ||
            reason == 'recorder_lease_expired' ||
            reason == 'recorder_ack_lag_exceeded' ||
            reason == 'recorder_first_frame_unavailable')) {
      _snapshot('recorder.resilient.degraded', fields: {'reason': reason});
      unawaited(_spillToSpool());
      return;
    }
    _snapshot('recorder.mandatory.violation',
        fields: {'reason': reason, 'result': 'stopping'});
    _stopped = true;
    _flushTimer?.cancel();
    _flushTimer = null;
    onMandatoryViolation?.call(reason);
  }
}
