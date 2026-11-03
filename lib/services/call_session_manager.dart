import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

enum CallStatus {
  idle,
  calling,
  connected,
  ended,
}

enum CallDisplayMode {
  hidden,
  fullscreen,
  pip,
}

/// Глобальный менеджер сессии вызова (Audio/Video WebRTC).
/// Обеспечивает непрерывность звонка при смене экранов и переход в PiP.
class CallSessionManager extends ChangeNotifier {
  static final CallSessionManager instance = CallSessionManager._();

  CallSessionManager._();
  factory CallSessionManager() => instance;

  CallStatus _status = CallStatus.idle;
  CallDisplayMode _displayMode = CallDisplayMode.hidden;
  String _chatId = '';
  String _chatTitle = '';
  bool _isVideo = false;
  bool _isMuted = false;
  bool _isCameraOff = false;
  bool _isScreenSharing = false;
  int _durationSeconds = 0;
  Timer? _callTimer;

  RTCVideoRenderer? _localRenderer;
  RTCVideoRenderer? _remoteRenderer;

  CallStatus get status => _status;
  CallDisplayMode get displayMode => _displayMode;
  String get chatId => _chatId;
  String get chatTitle => _chatTitle;
  bool get isVideo => _isVideo;
  bool get isMuted => _isMuted;
  bool get isCameraOff => _isCameraOff;
  bool get isScreenSharing => _isScreenSharing;
  int get durationSeconds => _durationSeconds;
  RTCVideoRenderer? get localRenderer => _localRenderer;
  RTCVideoRenderer? get remoteRenderer => _remoteRenderer;

  String get formattedDuration {
    final m = (_durationSeconds ~/ 60).toString().padLeft(2, '0');
    final s = (_durationSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  void startCall({
    required String chatId,
    required String chatTitle,
    required bool isVideo,
  }) {
    _chatId = chatId;
    _chatTitle = chatTitle;
    _isVideo = isVideo;
    _isMuted = false;
    _isCameraOff = !isVideo;
    _isScreenSharing = false;
    _durationSeconds = 0;
    _status = CallStatus.calling;
    _displayMode = CallDisplayMode.fullscreen;

    _callTimer?.cancel();
    _callTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      _durationSeconds++;
      if (_status == CallStatus.calling && _durationSeconds >= 2) {
        _status = CallStatus.connected;
      }
      notifyListeners();
    });

    notifyListeners();
  }

  void setPip(bool pip) {
    if (_status == CallStatus.idle) return;
    _displayMode = pip ? CallDisplayMode.pip : CallDisplayMode.fullscreen;
    notifyListeners();
  }

  void toggleMute() {
    _isMuted = !_isMuted;
    notifyListeners();
  }

  void toggleCamera() {
    _isCameraOff = !_isCameraOff;
    notifyListeners();
  }

  void toggleScreenShare() {
    _isScreenSharing = !_isScreenSharing;
    notifyListeners();
  }

  void endCall() {
    _callTimer?.cancel();
    _callTimer = null;
    _status = CallStatus.idle;
    _displayMode = CallDisplayMode.hidden;
    _chatId = '';
    _chatTitle = '';
    _durationSeconds = 0;
    _isScreenSharing = false;

    // Освобождение текстур WebRTC с отвязкой потоков
    if (_localRenderer != null) {
      _localRenderer!.srcObject = null;
    }
    if (_remoteRenderer != null) {
      _remoteRenderer!.srcObject = null;
    }

    notifyListeners();
  }

  Future<void> initRenderers() async {
    if (_localRenderer == null) {
      _localRenderer = RTCVideoRenderer();
      await _localRenderer!.initialize();
    }
    if (_remoteRenderer == null) {
      _remoteRenderer = RTCVideoRenderer();
      await _remoteRenderer!.initialize();
    }
    notifyListeners();
  }

  Future<void> disposeRenderers() async {
    if (_localRenderer != null) {
      _localRenderer!.srcObject = null;
      await _localRenderer!.dispose();
      _localRenderer = null;
    }
    if (_remoteRenderer != null) {
      _remoteRenderer!.srcObject = null;
      await _remoteRenderer!.dispose();
      _remoteRenderer = null;
    }
  }
}
