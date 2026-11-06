import 'dart:async';
import 'dart:io';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'call_kit_service.dart';

/// Плеер акустических сигналов телефонии и WebRTC вызовов (гудки КПВ, рингтон,
/// звук соединения, сигнал "занято" и завершение вызова).
/// - На Android: использует нативный системный ToneGenerator (STREAM_VOICE_CALL) через CallKitService,
///   чтобы исключить перехват AudioManager у WebRTC AudioSwitch и сбои MediaPlayer в audioplayers_android.
/// - На iOS: системный рингтон играет CallKit, а при старте WebRTC не создаётся конкурирующий AVAudioPlayer.
class CallSoundPlayer {
  static final CallSoundPlayer instance = CallSoundPlayer._();
  CallSoundPlayer._();
  factory CallSoundPlayer() => instance;

  AudioPlayer? _ringPlayer;
  AudioPlayer? _fxPlayer;

  bool get _isIOS => !kIsWeb && Platform.isIOS;
  bool get _isAndroid => !kIsWeb && Platform.isAndroid;

  AudioPlayer get _getRingPlayer => _ringPlayer ??= AudioPlayer();
  AudioPlayer get _getFxPlayer => _fxPlayer ??= AudioPlayer();

  AudioContext _buildVoipContext({required bool isVideo}) {
    return AudioContext(
      iOS: AudioContextIOS(
        category: AVAudioSessionCategory.playAndRecord,
        options: {
          AVAudioSessionOptions.mixWithOthers,
          AVAudioSessionOptions.allowBluetooth,
          AVAudioSessionOptions.allowBluetoothA2DP,
          if (isVideo) AVAudioSessionOptions.defaultToSpeaker,
        },
      ),
      android: AudioContextAndroid(
        isSpeakerphoneOn: isVideo,
        audioMode: AndroidAudioMode.inCommunication,
        stayAwake: false,
        contentType: AndroidContentType.speech,
        usageType: AndroidUsageType.voiceCommunication,
        audioFocus: AndroidAudioFocus.none,
      ),
    );
  }

  /// Запуск мягких ритмичных гудков ожидания ответа (КПВ) для звонящего
  Future<void> startRingback({required bool isVideo}) async {
    if (_isAndroid) {
      await CallKitService.instance.playCallTone('ringback');
      return;
    }
    try {
      final player = _getRingPlayer;
      await player.setAudioContext(_buildVoipContext(isVideo: isVideo));
      await player.setReleaseMode(ReleaseMode.loop);
      await player.play(AssetSource('sounds/ringback.wav'));
    } catch (e) {
      debugPrint('[CallSoundPlayer] startRingback error: $e');
    }
  }

  /// Остановка гудков КПВ
  Future<void> stopRingback() async {
    if (_isAndroid) {
      await CallKitService.instance.stopCallTone();
      return;
    }
    try {
      await _ringPlayer?.stop();
    } catch (_) {}
  }

  /// Запуск рингтона входящего вызова
  Future<void> startRingtone({bool isVideo = false}) async {
    // На iOS и Android системный рингтон воспроизводится нативным CallKit / NotificationChannel
    if (_isIOS || _isAndroid) return;
    try {
      final player = _getRingPlayer;
      await player.setAudioContext(_buildVoipContext(isVideo: isVideo));
      await player.setReleaseMode(ReleaseMode.loop);
      await player.play(AssetSource('sounds/ringtone.wav'));
    } catch (e) {
      debugPrint('[CallSoundPlayer] startRingtone error: $e');
    }
  }

  /// Остановка рингтона входящего вызова
  Future<void> stopRingtone() async {
    if (_isIOS || _isAndroid) return;
    try {
      await _ringPlayer?.stop();
    } catch (_) {}
  }

  /// Звук снятия трубки / установления P2P-соединения (160 мс Connect Chime)
  Future<void> playConnect({bool isVideo = false}) async {
    if (_isIOS) return;
    if (_isAndroid) {
      await CallKitService.instance.playCallTone('connect');
      return;
    }
    try {
      final player = _getFxPlayer;
      await player.setAudioContext(_buildVoipContext(isVideo: isVideo));
      await player.setReleaseMode(ReleaseMode.stop);
      await player.play(AssetSource('sounds/call_connect.wav'));
    } catch (_) {}
  }

  /// Звук "Занято" / "Вызов отклонён" (3 коротких гудка)
  Future<void> playBusy({bool isVideo = false}) async {
    if (_isIOS) return;
    if (_isAndroid) {
      await CallKitService.instance.playCallTone('busy');
      return;
    }
    try {
      final player = _getFxPlayer;
      await player.setAudioContext(_buildVoipContext(isVideo: isVideo));
      await player.setReleaseMode(ReleaseMode.stop);
      await player.play(AssetSource('sounds/call_busy.wav'));
    } catch (_) {}
  }

  /// Звук отбоя / завершения разговора (нисходящий тон)
  Future<void> playEnd({bool isVideo = false}) async {
    if (_isIOS) return;
    if (_isAndroid) {
      await CallKitService.instance.playCallTone('end');
      return;
    }
    try {
      final player = _getFxPlayer;
      await player.setAudioContext(_buildVoipContext(isVideo: isVideo));
      await player.setReleaseMode(ReleaseMode.stop);
      await player.play(AssetSource('sounds/call_end.wav'));
    } catch (_) {}
  }

  void dispose() {
    if (_isAndroid) {
      unawaited(CallKitService.instance.stopCallTone());
    }
    try {
      _ringPlayer?.dispose();
      _ringPlayer = null;
      _fxPlayer?.dispose();
      _fxPlayer = null;
    } catch (_) {}
  }
}
