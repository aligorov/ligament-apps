import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/io.dart';

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
  WebSocketChannel? _channel;
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

  String? _primaryBaseUrl;
  String? _token;
  List<String> _fallbackUrls = [];
  int _attemptIndex = 0;

  void connect({
    required String baseUrl,
    required String token,
    List<String> fallbackUrls = const [],
  }) {
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

  void _connectCandidate() {
    if (_disposed || _authFailed || _primaryBaseUrl == null || _token == null) return;

    final candidates = [_primaryBaseUrl!, ..._fallbackUrls];
    if (candidates.isEmpty) return;

    final targetUrl = candidates[_attemptIndex % candidates.length];
    final isRelay = (_attemptIndex % candidates.length) != 0;

    var wsUrl = targetUrl.trim();
    if (wsUrl.startsWith('https://')) {
      wsUrl = 'wss://${wsUrl.substring(8)}';
    } else {
      // Открытый ws:// запрещён: заголовок Authorization с Bearer-токеном
      // не должен покидать устройство в открытом виде (в т.ч. на relay).
      debugPrint('ws_service: кандидат "$targetUrl" пропущен: требуется https/wss');
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
        debugPrint('ws_service: итоговый URL "$wsUrl" не wss — отказ');
        _scheduleReconnect(advanceCandidate: true);
        return;
      }
      final headers = <String, String>{
        if (_token != null && _token!.isNotEmpty) 'Authorization': 'Bearer $_token',
      };

      _wasReady = false;
      _channel = IOWebSocketChannel.connect(
        uri,
        headers: headers,
        connectTimeout: const Duration(seconds: 4),
        pingInterval: const Duration(seconds: 20),
      );

      _channel!.ready.then((_) {
        if (!_disposed) {
          _wasReady = true;
          _backoff.reset();
          _armStableReset();
          currentEndpoint = targetUrl;
          isUsingRelay = isRelay;
          onEndpointChanged?.call(isRelay ? _extractHost(targetUrl) : null, isRelay);
          onConnected?.call();
        }
      }).catchError((Object e) {
        debugPrint('ws_service: соединение с $wsUrl не удалось: $e');
        if (!_disposed) {
          _channel = null;
          onDisconnected?.call();
          if (_isUnauthorized(e)) {
            _handleUnauthorized();
            return;
          }
          // Кандидат недоступен (handshake не прошёл) — сдвигаем индекс.
          _scheduleReconnect(advanceCandidate: true);
        }
      });

      _channel!.stream.listen(
        (message) {
          _handleMessage(message);
        },
        onDone: () {
          _channel = null;
          _stableResetTimer?.cancel();
          onDisconnected?.call();
          if (_disposed) return;
          // Соединение было установлено и закрыто сервером/сетью —
          // кандидат тот же, следующий коннект по backoff.
          _scheduleReconnect(advanceCandidate: false);
        },
        onError: (err) {
          debugPrint('ws_service: ошибка соединения $wsUrl: $err');
          _channel = null;
          _stableResetTimer?.cancel();
          onDisconnected?.call();
          if (_disposed) return;
          if (_isUnauthorized(err)) {
            _handleUnauthorized();
            return;
          }
          _scheduleReconnect(advanceCandidate: !_wasReady);
        },
        cancelOnError: true,
      );
    } catch (e) {
      debugPrint('ws_service: исключение при подключении к $wsUrl: $e');
      _scheduleReconnect(advanceCandidate: true);
    }
  }

  /// 401 распознаётся по строке ошибки: dart:io WebSocket не даёт
  /// типизированного статуса handshake-отказа (best effort).
  bool _isUnauthorized(Object err) {
    final s = err.toString().toLowerCase();
    return s.contains('401') || s.contains('unauthorized') || s.contains('connection denied');
  }

  void _handleUnauthorized() {
    debugPrint('ws_service: 401 на WS — цикл реконнектов остановлен, выход в разлогин');
    _authFailed = true;
    _channel = null;
    _reconnectTimer?.cancel();
    _stableResetTimer?.cancel();
    onUnauthorized?.call();
  }

  /// После 60с стабильного соединения сбрасываем backoff и индекс кандидатов:
  /// следующий обрыв начнёт с primary-сервера и задержки 1с.
  void _armStableReset() {
    _stableResetTimer?.cancel();
    _stableResetTimer = Timer(_stableResetDelay, () {
      if (!_disposed && _channel != null) {
        _backoff.reset();
        _attemptIndex = 0;
        debugPrint('ws_service: ${_stableResetDelay.inSeconds}с стабильного соединения — backoff и индекс кандидатов сброшены');
      }
    });
  }

  static String _extractHost(String url) {
    try {
      final u = Uri.parse(url);
      return u.host;
    } catch (_) {
      return url;
    }
  }

  void _scheduleReconnect({required bool advanceCandidate}) {
    if (_disposed || _authFailed) return;
    _reconnectTimer?.cancel();
    // Индекс кандидата сдвигается ТОЛЬКО при недоступности кандидата;
    // обрыв уже установленного соединения ретраит тот же кандидат.
    if (advanceCandidate) {
      _attemptIndex++;
    }
    final delay = _backoff.nextDelay();
    debugPrint('ws_service: повтор через ${delay.inMilliseconds}мс '
        '(кандидат ${_attemptIndex % ([_primaryBaseUrl!, ..._fallbackUrls].length)})');
    _reconnectTimer = Timer(delay, () {
      if (!_disposed && !_authFailed) {
        _connectCandidate();
      }
    });
  }

  void _handleMessage(dynamic message) {
    try {
      final text = message is String ? message : utf8.decode(message as List<int>);
      final data = jsonDecode(text) as Map<String, dynamic>;

      if (data['type'] == 'challenge_prompt' || data['type'] == 'push_prompt') {
        onPrompt?.call(data);
      } else if (data['type'] == 'support_prompt') {
        onSupportPrompt?.call(data);
      } else if (data['type'] == 'support_signal' || data['type'] == 'chat_message') {
        onSupportSignal?.call(data);
      } else if (data['type'] == 'support_ended') {
        onSupportEnded?.call(data);
      } else if (data['type'] == 'support_incoming_request' || data['type'] == 'support_queue_update') {
        onSupportIncoming?.call(data);
      }
    } catch (e) {
      debugPrint('ws_service: ошибка парсинга сообщения: $e');
    }
  }

  void sendJson(Map<String, dynamic> data) {
    try {
      _channel?.sink.add(jsonEncode(data));
    } catch (e) {
      debugPrint('ws_service: ошибка отправки: $e');
    }
  }

  void disconnect() {
    _disposed = true;
    _reconnectTimer?.cancel();
    _stableResetTimer?.cancel();
    _channel?.sink.close();
    _channel = null;
    currentEndpoint = null;
    isUsingRelay = false;
  }
}
