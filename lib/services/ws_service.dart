import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/io.dart';

typedef PushPromptCallback = void Function(Map<String, dynamic> prompt);
typedef EndpointChangeCallback = void Function(String? endpoint, bool isRelay);

/// Сервис постоянного WebSocket соединения для мгновенных push-уведомлений
/// с поддержкой автоматического failover на локальные Relay-узлы филиалов.
class WebSocketService {
  WebSocketChannel? _channel;
  Timer? _reconnectTimer;
  bool _disposed = false;

  PushPromptCallback? onPrompt;
  PushPromptCallback? onSupportPrompt;
  PushPromptCallback? onSupportSignal;
  PushPromptCallback? onSupportEnded;
  PushPromptCallback? onSupportIncoming;
  VoidCallback? onConnected;
  VoidCallback? onDisconnected;
  EndpointChangeCallback? onEndpointChanged;

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
    _primaryBaseUrl = baseUrl;
    _token = token;
    _fallbackUrls = List.from(fallbackUrls);
    _reconnectTimer?.cancel();
    _attemptIndex = 0;
    _connectCandidate();
  }

  void _connectCandidate() {
    if (_disposed || _primaryBaseUrl == null || _token == null) return;

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
      _scheduleNextCandidate();
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
        _scheduleNextCandidate();
        return;
      }
      final headers = <String, String>{
        if (_token != null && _token!.isNotEmpty) 'Authorization': 'Bearer $_token',
      };

      _channel = IOWebSocketChannel.connect(
        uri,
        headers: headers,
        connectTimeout: const Duration(seconds: 4),
        pingInterval: const Duration(seconds: 20),
      );

      _channel!.ready.then((_) {
        if (!_disposed) {
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
          _scheduleNextCandidate();
        }
      });

      _channel!.stream.listen(
        (message) {
          _handleMessage(message);
        },
        onDone: () {
          _channel = null;
          onDisconnected?.call();
          _scheduleNextCandidate();
        },
        onError: (err) {
          debugPrint('ws_service: ошибка соединения $wsUrl: $err');
          _channel = null;
          onDisconnected?.call();
          _scheduleNextCandidate();
        },
        cancelOnError: true,
      );
    } catch (e) {
      debugPrint('ws_service: исключение при подключении к $wsUrl: $e');
      _scheduleNextCandidate();
    }
  }

  static String _extractHost(String url) {
    try {
      final u = Uri.parse(url);
      return u.host;
    } catch (_) {
      return url;
    }
  }

  void _scheduleNextCandidate() {
    if (_disposed) return;
    _reconnectTimer?.cancel();
    _attemptIndex++;
    _reconnectTimer = Timer(const Duration(seconds: 3), () {
      if (!_disposed) {
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
    _channel?.sink.close();
    _channel = null;
    currentEndpoint = null;
    isUsingRelay = false;
  }
}
