import 'dart:async';
import 'dart:io';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

/// Плеер акустических сигналов телефонии и WebRTC вызовов (гудки КПВ, рингтон,
/// звук соединения, сигнал "занято" и завершение вызова).
/// Настроен на безопасный AudioContext (playAndRecord / voiceCommunication),
/// чтобы не сбивать и не перебивать WebRTC-пайплайн.
class CallSoundPlayer {
  static final CallSoundPlayer instance = CallSoundPlayer._();
  CallSoundPlayer._();
  factory CallSoundPlayer() => instance;

  AudioPlayer? _ringPlayer;
  AudioPlayer? _fxPlayer;

  bool get _isIOS => !kIsWeb && Platform.isIOS;

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
    try {
      await _ringPlayer?.stop();
    } catch (_) {}
  }

  /// Запуск рингтона входящего вызова
  Future<void> startRingtone({bool isVideo = false}) async {
    // На iOS системный рингтон играет сам CallKit — не перебиваем его AVAudioSession
    if (_isIOS) return;
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
    try {
      await _ringPlayer?.stop();
    } catch (_) {}
  }

  /// Звук снятия трубки / установления P2P-соединения (160 мс Connect Chime)
  Future<void> playConnect({bool isVideo = false}) async {
    // На iOS не запускаем отдельный AVAudioPlayer в момент старта WebRTC VoiceProcessingIO,
    // чтобы не сбить категорию playAndRecord и аппаратный маршрут динамика/микрофона.
    if (_isIOS) return;
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
    try {
      final player = _getFxPlayer;
      await player.setAudioContext(_buildVoipContext(isVideo: isVideo));
      await player.setReleaseMode(ReleaseMode.stop);
      await player.play(AssetSource('sounds/call_end.wav'));
    } catch (_) {}
  }

  void dispose() {
    try {
      _ringPlayer?.dispose();
      _ringPlayer = null;
      _fxPlayer?.dispose();
      _fxPlayer = null;
    } catch (_) {}
  }
}
