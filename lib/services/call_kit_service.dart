import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Сервис нативной интеграции телефонных вызовов (Apple CallKit на iOS и CallStyle/FGS на Android).
/// - На iOS: выводит вызовы в системный Apple CallKit (Lock Screen, Recents, Dynamic Island).
/// - На Android: выводит вызовы поверх экрана блокировки (FullScreenIntent, CallStyle, Foreground Service).
/// На остальных платформах (macOS, Windows, Linux, Web) работает как no-op.
class CallKitService {
  static final CallKitService instance = CallKitService._();
  factory CallKitService() => instance;

  CallKitService._() {
    if (isSupported) {
      _channel.setMethodCallHandler(_handleMethodCall);
    }
  }

  static const MethodChannel _channel = MethodChannel('ligament/callkit');

  /// Callback при ответе на звонок через системный экран (iOS CallKit / Android CallStyle)
  void Function(String uuid)? onCallAccepted;

  /// Callback при отклонении или завершении звонка через системный экран
  void Function(String uuid)? onCallEnded;

  /// Callback при переключении микрофона на системном экране
  void Function(bool muted)? onCallMuted;

  /// Callback при активации аудиосессии CallKit (iOS)
  void Function()? onAudioSessionActivated;

  bool get isSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android);

  Future<void> _handleMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'onCallAccepted':
        final uuid = call.arguments?['uuid'] as String? ?? '';
        onCallAccepted?.call(uuid);
        break;
      case 'onCallEnded':
        final uuid = call.arguments?['uuid'] as String? ?? '';
        onCallEnded?.call(uuid);
        break;
      case 'onCallMuted':
        final muted = call.arguments?['muted'] as bool? ?? false;
        onCallMuted?.call(muted);
        break;
      case 'onAudioSessionActivated':
        onAudioSessionActivated?.call();
        break;
      case 'onAudioSessionDeactivated':
        break;
    }
  }

  /// Отобразить нативный системный экран входящего вызова iOS (Lock Screen / Full Screen CallKit)
  Future<bool> reportIncomingCall({
    required String uuid,
    required String callerName,
    required bool hasVideo,
  }) async {
    if (!isSupported) return false;
    try {
      final res = await _channel.invokeMethod<bool>('reportIncomingCall', {
        'uuid': uuid,
        'callerName': callerName,
        'hasVideo': hasVideo,
      });
      return res == true;
    } catch (e) {
      debugPrint('[CallKitService] reportIncomingCall error: $e');
      return false;
    }
  }

  /// Зарегистрировать исходящий вызов в CallKit (Dynamic Island / статус-бар / Recents)
  Future<bool> startOutgoingCall({
    required String uuid,
    required String recipientName,
    required bool hasVideo,
  }) async {
    if (!isSupported) return false;
    try {
      final res = await _channel.invokeMethod<bool>('startOutgoingCall', {
        'uuid': uuid,
        'recipientName': recipientName,
        'hasVideo': hasVideo,
      });
      return res == true;
    } catch (e) {
      debugPrint('[CallKitService] startOutgoingCall error: $e');
      return false;
    }
  }

  /// Уведомить CallKit о принятии вызова из интерфейса приложения и активировать аудиосессию
  Future<void> answerCall({required String uuid, required bool hasVideo}) async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod('answerCall', {
        'uuid': uuid,
        'hasVideo': hasVideo,
      });
    } catch (e) {
      debugPrint('[CallKitService] answerCall error: $e');
    }
  }

  /// Принудительно активировать нативную аудиосессию WebRTC (iOS RTCAudioSession / Android AudioManager)
  Future<void> activateAudio({required bool hasVideo}) async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod('activateAudio', {'hasVideo': hasVideo});
    } catch (e) {
      debugPrint('[CallKitService] activateAudio error: $e');
    }
  }

  /// Уведомить CallKit об успешном соединении
  Future<void> reportConnected({required String uuid}) async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod('reportOutgoingCallConnected', {'uuid': uuid});
    } catch (e) {
      debugPrint('[CallKitService] reportConnected error: $e');
    }
  }

  /// Завершить вызов в CallKit
  Future<void> endCall({required String uuid}) async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod('endCall', {'uuid': uuid});
    } catch (e) {
      debugPrint('[CallKitService] endCall error: $e');
    }
  }

  /// Синхронизировать статус mute с CallKit / Android CallStyle
  Future<void> setMuted({required String uuid, required bool muted}) async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod('setMuted', {'uuid': uuid, 'muted': muted});
    } catch (e) {
      debugPrint('[CallKitService] setMuted error: $e');
    }
  }

  /// Проверка доступности полноэкранных уведомлений поверх экрана блокировки (Android 14+ FSI)
  Future<bool> canUseFullScreenIntent() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return true;
    try {
      final res = await _channel.invokeMethod<bool>('canUseFullScreenIntent');
      return res ?? true;
    } catch (_) {
      return true;
    }
  }

  /// Переход в системные настройки для предоставления доступа к полноэкранным уведомлениям (Android 14+)
  Future<void> requestFullScreenIntentPermission() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _channel.invokeMethod('requestFullScreenIntentPermission');
    } catch (e) {
      debugPrint('[CallKitService] requestFullScreenIntentPermission error: $e');
    }
  }

  /// Запуск фонового удержания сокета для приёма входящих вызовов в свёрнутом состоянии
  Future<void> startBackgroundKeepAlive() async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod('startBackgroundKeepAlive');
    } catch (e) {
      debugPrint('[CallKitService] startBackgroundKeepAlive error: $e');
    }
  }

  /// Остановка фонового удержания сокета при выходе из аккаунта
  Future<void> stopBackgroundKeepAlive() async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod('stopBackgroundKeepAlive');
    } catch (e) {
      debugPrint('[CallKitService] stopBackgroundKeepAlive error: $e');
    }
  }
}
