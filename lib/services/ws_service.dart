import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/io.dart';
import 'debug_log_service.dart';
import 'support_service.dart' show supportDebugMessageType;

typedef PushPromptCallback = void Function(Map<String, dynamic> prompt);
typedef EndpointChangeCallback = void Function(String? endpoint, bool isRelay);

/// Экспоненциальный backoff для WS-реконнекта (M-2):
/// 1с -> 2с -> 4с -> ... -> 30с (капа), с джиттером +-20% против
/// синхронных штормов реконнектов. После [stableResetDelay] стабильного
/// соединения счётчик сбрасывается (управляет WebSocketService).
///
/// Чистая логика — покрыта юнит-тестами без сети.
class ReconnectBackoff {
  ReconnectBackoff({
    this.baseMs = 1000,
    this.maxMs = 30000,
    this.jitterFraction = 0.2,
    Random? random,
  }) : _random = random ?? Random();

  final int baseMs;
  final int maxMs;
  final double jitterFraction;
  final Random _random;

  int _attempt = 0;

  /// Число неудачных попыток подряд с последнего сброса.
  int get attempt => _attempt;

  /// Вычисляет задержку для следующей попытки (с джиттером) и увеличивает
  /// счётчик. Задержки растут как base * 2^attempt, но не выше maxMs.
  Duration nextDelay() {
    final exp = _attempt;
    _attempt++;
    var delayMs = (baseMs * pow(2, exp)).round();
    if (delayMs > maxMs) delayMs = maxMs;
    if (jitterFraction > 0) {
      final j = (_random.nextDouble() * 2 - 1) * jitterFraction;
      delayMs = (delayMs * (1 + j)).round();
    }
    return Duration(milliseconds: delayMs.clamp(0, maxMs));
  }

  /// Сброс после стабильного соединения.
  void reset() {
    _attempt = 0;
  }
}

/// Сервис постоянного WebSocket соединения для мгновенных push-уведомлений
/// с поддержкой автоматического failover на локальные Relay-узлы филиалов.
class WebSocketService {
  WebSocketService({
    @visibleForTesting
    WebSocketChannel Function(Uri uri, Map<String, String> headers)?
        channelFactory,
  }) : _channelFactory = channelFactory;

  final WebSocketChannel Function(Uri uri, Map<String, String> headers)?
      _channelFactory;
  WebSocketChannel? _channel;
  int _generation = 0;
  int _connectionAttempt = 0;
  Timer? _reconnectTimer;
  Timer? _stableResetTimer;
  bool _disposed = false;
  bool _authFailed = false;

  /// Текущее соединение было установлено (handshake ok): обрыв после этого —
  /// серверная/сетевая проблема, кандидат НЕ сдвигается (M-2).
  bool _wasReady = false;

  static const Duration _stableResetDelay = Duration(seconds: 60);

  final ReconnectBackoff _backoff = ReconnectBackoff();

  PushPromptCallback? onPrompt;
  PushPromptCallback? onChallengeResolved;
  PushPromptCallback? onBrowserSso;
  PushPromptCallback? onNotification;
  PushPromptCallback? onSupportPrompt;
  PushPromptCallback? onSupportSignal;
  PushPromptCallback? onSupportEnded;
  PushPromptCallback? onSupportIncoming;
  VoidCallback? onConnected;
  VoidCallback? onDisconnected;
  EndpointChangeCallback? onEndpointChanged;

  /// 401 на handshake WS: токен недействителен, цикл реконнектов
  /// останавливается, AuthState переводит приложение в разлогин.
  VoidCallback? onUnauthorized;

  bool get isConnected => _channel != null;
  String? currentEndpoint;
  bool isUsingRelay = false;

  void _wsLog(String event,
      {Object? error, Map<String, Object?> fields = const {}}) {
    DebugLogService.instance.record(event, error: error, fields: {
      'attempt': _connectionAttempt,
      'connected': _wasReady && _channel != null,
      'transport': isUsingRelay ? 'relay' : 'wss',
      ...fields,
    });
  }

  String? _primaryBaseUrl;
  String? _token;
  List<String> _fallbackUrls = [];
  int _attemptIndex = 0;

  void connect({
    required String baseUrl,
    required String token,
    List<String> fallbackUrls = const [],
  }) {
    final uri = Uri.tryParse(baseUrl);
    _wsLog('ws.connect.request', fields: {
      'server': uri == null
          ? null
          : uri.hasPort
              ? '${uri.host}:${uri.port}'
              : uri.host,
      'method': 'GET',
      'route': '/api/v1/app/ws',
      'count': fallbackUrls.length
    });
    _closeCurrentChannel();
    _disposed = false;
    _authFailed = false;
    _primaryBaseUrl = baseUrl;
    _token = token;
    _fallbackUrls = List.from(fallbackUrls);
    _reconnectTimer?.cancel();
    _backoff.reset();
    _attemptIndex = 0;
    _connectCandidate();
  }

  void _closeCurrentChannel() {
    _generation++;
    final previous = _channel;
    _channel = null;
    if (previous != null) _wsLog('ws.close', fields: {'result': 'requested'});
    previous?.sink.close();
    _stableResetTimer?.cancel();
  }

  bool _isCurrent(int generation, WebSocketChannel channel) =>
      !_disposed && _generation == generation && identical(_channel, channel);

  void _connectCandidate([int? expectedGeneration]) {
    // Локальный биндинг вместо `_primaryBaseUrl!`/`_token!`: между проверкой
    // и использованием объект мог быть разобран параллельным disconnect().
    final primary = _primaryBaseUrl;
    final tok = _token;
    if (_disposed ||
        _authFailed ||
        primary == null ||
        tok == null ||
        (expectedGeneration != null && expectedGeneration != _generation)) {
      return;
    }

    final candidates = [primary, ..._fallbackUrls];
    if (candidates.isEmpty) return;

    final targetUrl = candidates[_attemptIndex % candidates.length];
    final isRelay = (_attemptIndex % candidates.length) != 0;
    _connectionAttempt++;

    final watch = Stopwatch()..start();
    final target = Uri.tryParse(targetUrl);
    _wsLog('ws.connect.begin', fields: {
      'server': target == null
          ? null
          : target.hasPort
              ? '${target.host}:${target.port}'
              : target.host,
      'method': 'GET',
      'route': isRelay ? '/api/v1/ws' : '/api/v1/app/ws',
      'transport': isRelay ? 'relay' : 'wss',
      'attempt': _connectionAttempt,
      'timeout_ms': 4000
    });
    var wsUrl = targetUrl.trim();
    if (wsUrl.startsWith('https://')) {
      wsUrl = 'wss://${wsUrl.substring(8)}';
    } else {
      // Открытый ws:// запрещён: заголовок Authorization с Bearer-токеном
      // не должен покидать устройство в открытом виде (в т.ч. на relay).

      _wsLog('ws.connect.blocked', fields: {'reason': 'insecure_scheme'});
      _scheduleReconnect(advanceCandidate: true);
      return;
    }
    if (wsUrl.endsWith('/')) {
      wsUrl = wsUrl.substring(0, wsUrl.length - 1);
    }
    wsUrl = isRelay ? '$wsUrl/api/v1/ws' : '$wsUrl/api/v1/app/ws';

    try {
      final uri = Uri.parse(wsUrl);
      if (uri.scheme != 'wss') {
        _scheduleReconnect(advanceCandidate: true);
        return;
      }
      final headers = <String, String>{
        if (tok.isNotEmpty) 'Authorization': 'Bearer $tok',
      };

      _closeCurrentChannel();
      final generation = _generation;
      final channel = _channelFactory?.call(uri, headers) ??
          IOWebSocketChannel.connect(
            uri,
            headers: headers,
            connectTimeout: const Duration(seconds: 4),
            pingInterval: const Duration(seconds: 20),
          );
      _channel = channel;
      _wasReady = false;

      channel.ready.then((_) {
        if (!_isCurrent(generation, channel)) return;
        _wasReady = true;
        _wsLog('ws.ready', fields: {
          'duration_ms': watch.elapsedMilliseconds,
          'server': uri.hasPort ? '${uri.host}:${uri.port}' : uri.host,
          'method': 'GET',
          'route': isRelay ? '/api/v1/ws' : '/api/v1/app/ws',
          'transport': isRelay ? 'relay' : 'wss'
        });
        _backoff.reset();
        _armStableReset(generation, channel);
        currentEndpoint = targetUrl;
        isUsingRelay = isRelay;
        onEndpointChanged?.call(
            isRelay ? _extractHost(targetUrl) : null, isRelay);
        onConnected?.call();
      }).catchError((Object e) {
        _wsLog('ws.handshake.failed', error: e, fields: {
          'duration_ms': watch.elapsedMilliseconds,
          'server': uri.hasPort ? '${uri.host}:${uri.port}' : uri.host,
          'method': 'GET',
          'route': isRelay ? '/api/v1/ws' : '/api/v1/app/ws',
        });

        if (!_isCurrent(generation, channel)) return;
        _channel = null;
        channel.sink.close();
        _stableResetTimer?.cancel();
        onDisconnected?.call();
        if (_isUnauthorized(e)) {
          _handleUnauthorized();
          return;
        }
        // Кандидат недоступен (handshake не прошёл) — сдвигаем индекс.
        _scheduleReconnect(advanceCandidate: true);
      });

      channel.stream.listen(
        (message) {
          if (_isCurrent(generation, channel)) _handleMessage(message);
        },
        onDone: () {
          _wsLog('ws.done',
              fields: {'code': channel.closeCode, 'origin': 'ws_state'});
          if (!_isCurrent(generation, channel)) return;
          _channel = null;
          _stableResetTimer?.cancel();
          onDisconnected?.call();
          // Соединение было установлено и закрыто сервером/сетью —
          // кандидат тот же, следующий коннект по backoff.
          _scheduleReconnect(advanceCandidate: false);
        },
        onError: (err) {
          _wsLog('ws.error', error: err, fields: {'origin': 'ws_state'});

          if (!_isCurrent(generation, channel)) return;
          _channel = null;
          channel.sink.close();
          _stableResetTimer?.cancel();
          onDisconnected?.call();
          if (_isUnauthorized(err)) {
            _handleUnauthorized();
            return;
          }
          _scheduleReconnect(advanceCandidate: !_wasReady);
        },
        cancelOnError: true,
      );
    } catch (e) {
      _wsLog('ws.exception',
          error: e, fields: {'phase': 'connect_candidate', 'result': 'failed'});

      _scheduleReconnect(advanceCandidate: true);
    }
  }

  /// 401 распознаётся по строке ошибки: dart:io WebSocket не даёт
  /// типизированного статуса handshake-отказа (best effort).
  /// 401 матчится по границам цифр — иначе ловятся ложные совпадения
  /// вида IP-адреса 10.0.40.1x в тексте ошибки.
  bool _isUnauthorized(Object err) {
    final s = err.toString().toLowerCase();
    final is401 = RegExp(r'(^|[^0-9])401([^0-9]|$)').hasMatch(s);
    return is401 ||
        s.contains('unauthorized') ||
        s.contains('connection denied');
  }

  void _handleUnauthorized() {
    _wsLog('ws.auth.failed', fields: {'http_status': 401, 'result': 'stopped'});
    _authFailed = true;
    _channel = null;
    _reconnectTimer?.cancel();
    _stableResetTimer?.cancel();
    onUnauthorized?.call();
  }

  /// После 60с стабильного соединения сбрасываем backoff и индекс кандидатов:
  /// следующий обрыв начнёт с primary-сервера и задержки 1с.
  void _armStableReset(int generation, WebSocketChannel channel) {
    _stableResetTimer?.cancel();
    _stableResetTimer = Timer(_stableResetDelay, () {
      if (_isCurrent(generation, channel)) {
        _backoff.reset();
        _attemptIndex = 0;
      }
    });
  }

  static String _extractHost(String url) {
    try {
      final u = Uri.parse(url);
      return u.host;
    } catch (error) {
      DebugLogService.instance.record('ws.exception',
          error: error, fields: {'phase': 'extract_host', 'result': 'failed'});
      return url;
    }
  }

  void _scheduleReconnect({required bool advanceCandidate}) {
    if (_disposed || _authFailed) return;
    _reconnectTimer?.cancel();
    final generation = _generation;
    final channelAtSchedule = _channel;
    // Индекс кандидата сдвигается ТОЛЬКО при недоступности кандидата;
    // обрыв уже установленного соединения ретраит тот же кандидат.
    if (advanceCandidate) {
      _attemptIndex++;
    }
    final delay = _backoff.nextDelay();
    _wsLog('ws.reconnect.scheduled', fields: {
      'timeout_ms': delay.inMilliseconds,
      'operation': advanceCandidate ? 'advance_candidate' : 'same_candidate'
    });
    // Считаем кандидатов без `!`: primary мог быть разобран disconnect'ом.
    final totalCandidates =
        (_primaryBaseUrl != null ? 1 : 0) + _fallbackUrls.length;
    _wsLog('ws.reconnect.candidates', fields: {'candidates': totalCandidates});
    _reconnectTimer = Timer(delay, () {
      if (!_disposed &&
          !_authFailed &&
          _generation == generation &&
          identical(_channel, channelAtSchedule)) {
        _connectCandidate(generation);
      }
    });
  }

  void _handleMessage(dynamic message) {
    try {
      final text =
          message is String ? message : utf8.decode(message as List<int>);
      final data = jsonDecode(text) as Map<String, dynamic>;
      _wsLog('ws.message.inbound', fields: {
        'message_type': supportDebugMessageType(data['type']),
        'bytes': utf8.encode(text).length
      });

      if (data['type'] == 'challenge_prompt' || data['type'] == 'push_prompt') {
        onPrompt?.call(data);
      } else if (data['type'] == 'challenge_resolved' ||
          data['type'] == 'challenge_closed' ||
          data['type'] == 'challenge_cancelled') {
        onChallengeResolved?.call(data);
      } else if (data['type'] == 'browser_sso') {
        // Фаза 2b: SSO-мост — вход в SAML/OIDC-сервис по CP-билету.
        // Полезная нагрузка может лежать прямо в сообщении или в 'challenge'.
        final payload = (data['challenge'] is Map)
            ? Map<String, dynamic>.from(data['challenge'] as Map)
            : data;
        onBrowserSso?.call(payload);
      } else if (data['type'] == 'support_prompt') {
        onSupportPrompt?.call(data);
      } else if (data['type'] == 'support_signal' ||
          data['type'] == 'chat_message') {
        onSupportSignal?.call(data);
      } else if (data['type'] == 'support_ended') {
        onSupportEnded?.call(data);
      } else if (data['type'] == 'support_incoming_request' ||
          data['type'] == 'support_queue_update') {
        onSupportIncoming?.call(data);
      } else if (data['type'] == 'notification') {
        if (data['id'] != null) {
          sendJson({'action': 'notify_delivered', 'id': data['id']});
        }
        onNotification?.call(data);
      }
    } catch (e) {
      _wsLog('ws.exception', error: e, fields: {
        'phase': 'handle_message',
        'message_type': 'unknown',
        'bytes': message is String
            ? utf8.encode(message).length
            : message is List<int>
                ? message.length
                : 0,
        'result': 'failed'
      });
    }
  }

  void sendJson(Map<String, dynamic> data) {
    try {
      final text = jsonEncode(data);
      _channel?.sink.add(text);
      _wsLog('ws.message.outbound', fields: {
        'message_type': supportDebugMessageType(data['type'] ?? data['action']),
        'bytes': utf8.encode(text).length,
        'result': _channel == null ? 'blocked' : 'queued'
      });
    } catch (e) {
      _wsLog('ws.exception', error: e, fields: {
        'phase': 'send_json',
        'message_type': supportDebugMessageType(data['type'] ?? data['action']),
        'result': 'failed'
      });
    }
  }

  void disconnect() {
    _wsLog('ws.disconnect', fields: {'origin': 'user'});
    _disposed = true;
    _reconnectTimer?.cancel();
    _closeCurrentChannel();
    _primaryBaseUrl = null;
    _token = null;
    _fallbackUrls = [];
    currentEndpoint = null;
    isUsingRelay = false;
  }
}
