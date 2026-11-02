import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

typedef PushTokenCallback = void Function(String token);
typedef PushPayloadCallback = void Function(Map<String, dynamic> payload);
typedef PushActionCallback = void Function(
  String action,
  String? challengeId,
  Map<String, dynamic> payload,
);

/// Сервис нативных системных push-уведомлений (APNs для iOS и macOS).
class PushService {
  static const MethodChannel _channel = MethodChannel('ligament/push');

  static final PushService _instance = PushService._internal();
  factory PushService() => _instance;
  PushService._internal();

  PushTokenCallback? onPushToken;
  PushPayloadCallback? onRemoteNotification;
  PushActionCallback? onNotificationAction;

  String? _pushToken;
  String? get pushToken => _pushToken;

  bool _initialized = false;

  /// Инициализирует обработчики нативного канала push-уведомлений.
  Future<void> init() async {
    if (_initialized) return;
    if (kIsWeb || (!Platform.isIOS && !Platform.isMacOS)) {
      return;
    }

    _channel.setMethodCallHandler(_handleNativeCall);

    try {
      final res = await _channel.invokeMapMethod<String, dynamic>('registerForPush');
      final tok = res?['token']?.toString();
      if (tok != null && tok.isNotEmpty) {
        _pushToken = tok;
        onPushToken?.call(tok);
      }
    } catch (e) {
      debugPrint('push_service: ошибка registerForPush: $e');
    }

    try {
      final initial = await _channel.invokeMapMethod<String, dynamic>('getInitialNotification');
      if (initial != null) {
        _handleInitialNotification(initial);
      }
    } catch (e) {
      debugPrint('push_service: ошибка getInitialNotification: $e');
    }

    _initialized = true;
  }

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'onPushToken':
        final tok = call.arguments?.toString();
        if (tok != null && tok.isNotEmpty) {
          _pushToken = tok;
          onPushToken?.call(tok);
        }
        break;
      case 'onRemoteNotification':
        if (call.arguments is Map) {
          final map = Map<String, dynamic>.from(call.arguments as Map);
          onRemoteNotification?.call(map);
        }
        break;
      case 'onNotificationAction':
        if (call.arguments is Map) {
          final map = Map<String, dynamic>.from(call.arguments as Map);
          final action = map['action']?.toString() ?? 'OPEN';
          final payload = (map['payload'] is Map)
              ? Map<String, dynamic>.from(map['payload'] as Map)
              : <String, dynamic>{};
          final challengeId = payload['challenge_id']?.toString() ??
              payload['challengeId']?.toString();
          onNotificationAction?.call(action, challengeId, payload);
        }
        break;
      default:
        break;
    }
  }

  void _handleInitialNotification(Map<String, dynamic> initial) {
    final action = initial['action']?.toString() ?? 'OPEN';
    final payload = (initial['payload'] is Map)
        ? Map<String, dynamic>.from(initial['payload'] as Map)
        : <String, dynamic>{};
    final challengeId = payload['challenge_id']?.toString() ??
        payload['challengeId']?.toString();
    onNotificationAction?.call(action, challengeId, payload);
  }
}
