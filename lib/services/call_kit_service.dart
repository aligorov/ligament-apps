import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Сервис нативной интеграции Apple CallKit для iOS.
/// На iOS выводит входящие и исходящие звонки в системный интерфейс Apple Phone / Lock Screen
/// с нативными кнопками ответа/отклонения, рингтоном системы и историей вызовов в Recents.
/// На остальных платформах (Android, macOS, Windows, Linux, Web) работает как no-op.
class CallKitService {
  static final CallKitService instance = CallKitService._();
  factory CallKitService() => instance;

  CallKitService._() {
    if (isSupported) {
      _channel.setMethodCallHandler(_handleMethodCall);
    }
  }

  static const MethodChannel _channel = MethodChannel('ligament/callkit');

  /// Callback при ответе на звонок через системный экран iOS CallKit
  void Function(String uuid)? onCallAccepted;

  /// Callback при отклонении или завершении звонка через системный экран iOS CallKit
  void Function(String uuid)? onCallEnded;

  /// Callback при переключении микрофона на системном экране iOS CallKit
  void Function(bool muted)? onCallMuted;

  bool get isSupported => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

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

  /// Синхронизировать статус mute с CallKit
  Future<void> setMuted({required String uuid, required bool muted}) async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod('setMuted', {'uuid': uuid, 'muted': muted});
    } catch (e) {
      debugPrint('[CallKitService] setMuted error: $e');
    }
  }
}
