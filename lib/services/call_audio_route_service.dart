import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'call_kit_service.dart';

/// Сервис управления маршрутизацией звука вызова (Loudspeaker vs Earpiece vs Bluetooth).
/// Гарантирует корректную работу на мобильных ОС (iOS/Android) с защитой от сбоев
/// на десктопных платформах (Windows, macOS, Linux, Web), где вызовы setSpeakerphoneOn запрещены.
class CallAudioRouteService {
  static final CallAudioRouteService instance = CallAudioRouteService._();
  CallAudioRouteService._();
  factory CallAudioRouteService() => instance;

  bool _isSpeaker = false;
  bool get isSpeaker => _isSpeaker;

  /// Синхронная установка дефолтного маршрута при старте звонка до инициализации медиа
  void prepareDefaultRoute({required bool isVideo}) {
    _isSpeaker = isVideo;
  }

  /// Обновление статуса динамика при переключении из нативного CallKit / системы
  void updateSpeakerFromNative(bool isSpeaker) {
    _isSpeaker = isSpeaker;
  }

  /// Проверка, поддерживается ли мобильное переключение динамика
  bool get isMobileRoutingSupported {
    if (kIsWeb) return false;
    return Platform.isAndroid || Platform.isIOS;
  }

  /// Первичная конфигурация аудиосессии под VoIP перед подключением медиа
  Future<void> configureSession({required bool isVideo}) async {
    if (!isMobileRoutingSupported) return;

    try {
      if (Platform.isIOS) {
        await Helper.setAppleAudioConfiguration(
          AppleAudioConfiguration(
            appleAudioCategory: AppleAudioCategory.playAndRecord,
            appleAudioMode: AppleAudioMode.voiceChat,
            appleAudioCategoryOptions: {
              AppleAudioCategoryOption.allowBluetooth,
              AppleAudioCategoryOption.allowBluetoothA2DP,
              AppleAudioCategoryOption.allowAirPlay,
            },
          ),
        );
      } else if (Platform.isAndroid) {
        await Helper.setAndroidAudioConfiguration(
          AndroidAudioConfiguration(
            manageAudioFocus: true,
            androidAudioMode: AndroidAudioMode.inCommunication,
            androidAudioFocusMode: AndroidAudioFocusMode.gain,
            androidAudioStreamType: AndroidAudioStreamType.voiceCall,
            androidAudioAttributesUsageType: AndroidAudioAttributesUsageType.voiceCommunication,
            androidAudioAttributesContentType: AndroidAudioAttributesContentType.speech,
          ),
        );
      }
    } catch (e) {
      debugPrint('[CallAudioRouteService] configureSession error: $e');
    }
  }

  /// Маршрутизация звука:
  /// - Видеозвонок по умолчанию: Громкая связь (Loudspeaker с приоритетом Bluetooth).
  /// - Аудиозвонок по умолчанию: Разговорный слуховой динамик у уха (Earpiece).
  Future<void> applyRouting({required bool isVideo, bool? forceSpeaker}) async {
    _isSpeaker = forceSpeaker ?? isVideo;

    if (!isMobileRoutingSupported) return;

    try {
      if (Platform.isIOS) {
        await CallKitService.instance.setSpeaker(_isSpeaker);
      }
      if (_isSpeaker) {
        // Уважаем AirPods / гарнитуры: если наушники подключены, звук остаётся в них!
        await Helper.setSpeakerphoneOnButPreferBluetooth();
      } else {
        // Направляем в разговорный ушной динамик
        await Helper.setSpeakerphoneOn(false);
      }
    } catch (e) {
      debugPrint('[CallAudioRouteService] applyRouting error: $e');
    }
  }

  /// Переключение громкой связи пользователем вручную
  Future<void> toggleSpeaker({required bool isVideo}) async {
    await applyRouting(isVideo: isVideo, forceSpeaker: !_isSpeaker);
  }

  /// Сброс настроек при завершении вызова
  Future<void> reset() async {
    _isSpeaker = false;
    if (!isMobileRoutingSupported) return;

    try {
      if (Platform.isAndroid) {
        await Helper.clearAndroidCommunicationDevice();
      }
      await Helper.setSpeakerphoneOn(false);
    } catch (_) {}
  }
}
