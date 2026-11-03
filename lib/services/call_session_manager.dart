import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'debug_log_service.dart';

enum CallStatus {
  idle,
  calling,
  incoming,
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
  String _targetUserId = '';
  String _callerName = '';
  bool _isVideo = false;
  bool _isMuted = false;
  bool _isCameraOff = false;
  bool _isScreenSharing = false;
  int _durationSeconds = 0;
  Timer? _callTimer;
  Timer? _ringTimeout;

  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  MediaStream? _remoteStream;
  final List<RTCIceCandidate> _remoteIceCandidateQueue = [];
  bool _remoteDescriptionSet = false;
  String _pendingOfferSdp = '';

  RTCVideoRenderer? _localRenderer;
  RTCVideoRenderer? _remoteRenderer;

  /// Callback для отправки WebRTC сигналинга (offer, answer, candidate, hangup, rejected, busy)
  void Function(String targetUserId, String chatId, Map<String, dynamic> payload)? onSendSignal;

  CallStatus get status => _status;
  CallDisplayMode get displayMode => _displayMode;
  String get chatId => _chatId;
  String get chatTitle => _chatTitle;
  String get targetUserId => _targetUserId;
  String get callerName => _callerName;
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

  /// Старт исходящего вызова
  void startCall({
    required String chatId,
    required String chatTitle,
    required bool isVideo,
    String targetUserId = '',
    List<Map<String, dynamic>> iceServers = const [],
  }) {
    _chatId = chatId;
    _chatTitle = chatTitle;
    _targetUserId = targetUserId.isNotEmpty ? targetUserId : chatTitle;
    _callerName = chatTitle;
    _isVideo = isVideo;
    _isMuted = false;
    _isCameraOff = !isVideo;
    _isScreenSharing = false;
    _durationSeconds = 0;
    _status = CallStatus.calling;
    _displayMode = CallDisplayMode.fullscreen;
    _remoteDescriptionSet = false;
    _remoteIceCandidateQueue.clear();

    _ringTimeout?.cancel();
    _ringTimeout = Timer(const Duration(seconds: 45), () {
      if (_status == CallStatus.calling) {
        endCall(notifyPeer: true);
      }
    });

    notifyListeners();

    unawaited(_initAndStartWebRTC(isVideo: isVideo, iceServers: iceServers));
  }

  Future<void> _initAndStartWebRTC({
    required bool isVideo,
    required List<Map<String, dynamic>> iceServers,
  }) async {
    try {
      await initRenderers();
    } catch (_) {}

    try {
      final mediaConstraints = <String, dynamic>{
        'audio': true,
        'video': isVideo
            ? {
                'mandatory': {
                  'minWidth': '640',
                  'minHeight': '480',
                  'minFrameRate': '30',
                },
                'facingMode': 'user',
                'optional': [],
              }
            : false,
      };

      _localStream = await navigator.mediaDevices.getUserMedia(mediaConstraints);
      if (_localRenderer != null) {
        try {
          _localRenderer!.srcObject = _localStream;
        } catch (_) {}
      }

      final configuration = <String, dynamic>{
        'iceServers': iceServers.isNotEmpty
            ? iceServers
            : [
                {
                  'urls': [
                    'stun:remote.grando.app:3478',
                    'turn:remote.grando.app:3478?transport=udp',
                    'turn:remote.grando.app:3478?transport=tcp',
                  ],
                  'username': 'ligament',
                  'credential': 'ligament-secret-turn-key',
                }
              ],
        'sdpSemantics': 'unified-plan',
        'bundlePolicy': 'max-bundle',
      };

      _peerConnection = await createPeerConnection(configuration);

      for (final track in _localStream!.getTracks()) {
        await _peerConnection!.addTrack(track, _localStream!);
      }

      _peerConnection!.onIceCandidate = (candidate) {
        if (candidate.candidate != null && _targetUserId.isNotEmpty) {
          onSendSignal?.call(_targetUserId, _chatId, {
            'type': 'candidate',
            'candidate': {
              'candidate': candidate.candidate,
              'sdpMid': candidate.sdpMid,
              'sdpMLineIndex': candidate.sdpMLineIndex,
            },
          });
        }
      };

      _peerConnection!.onTrack = (event) {
        if (event.streams.isNotEmpty) {
          _remoteStream = event.streams[0];
          if (_remoteRenderer != null) {
            try {
              _remoteRenderer!.srcObject = _remoteStream;
            } catch (_) {}
          }
          notifyListeners();
        }
      };

      _peerConnection!.onConnectionState = (state) {
        if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
          _ringTimeout?.cancel();
          _ringTimeout = null;
          _status = CallStatus.connected;
          _startDurationTimer();
          notifyListeners();
        } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
            state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
          endCall(notifyPeer: true);
        }
      };

      final offer = await _peerConnection!.createOffer();
      await _peerConnection!.setLocalDescription(offer);

      onSendSignal?.call(_targetUserId, _chatId, {
        'type': 'offer',
        'sdp': offer.sdp,
        'is_video': isVideo,
        'caller_name': _callerName,
      });
    } catch (e) {
      DebugLogService.instance.record('webrtc.start.failed', error: e);
    }
  }

  /// Обработка входящего вызова (offer)
  void handleIncomingOffer({
    required String fromUser,
    required String chatId,
    required Map<String, dynamic> offerPayload,
  }) {
    if (_status != CallStatus.idle) {
      onSendSignal?.call(fromUser, chatId, {'type': 'busy'});
      return;
    }

    _status = CallStatus.incoming;
    _chatId = chatId;
    _targetUserId = fromUser;
    final caller = offerPayload['caller_name'] as String?;
    _callerName = (caller != null && caller.trim().isNotEmpty) ? caller.trim() : fromUser;
    _chatTitle = _callerName;
    _isVideo = offerPayload['is_video'] == true;
    _isMuted = false;
    _isCameraOff = !_isVideo;
    _isScreenSharing = false;
    _displayMode = CallDisplayMode.fullscreen;
    _pendingOfferSdp = offerPayload['sdp'] as String? ?? '';
    _remoteDescriptionSet = false;
    _remoteIceCandidateQueue.clear();

    _ringTimeout?.cancel();
    _ringTimeout = Timer(const Duration(seconds: 45), () {
      if (_status == CallStatus.incoming) {
        rejectIncomingCall();
      }
    });

    notifyListeners();
  }

  /// Принять входящий вызов
  Future<void> acceptIncomingCall({List<Map<String, dynamic>> iceServers = const []}) async {
    if (_status != CallStatus.incoming || _pendingOfferSdp.isEmpty) return;

    _ringTimeout?.cancel();
    _ringTimeout = null;
    _status = CallStatus.calling;
    notifyListeners();

    await initRenderers();

    try {
      final mediaConstraints = <String, dynamic>{
        'audio': true,
        'video': _isVideo
            ? {
                'mandatory': {
                  'minWidth': '640',
                  'minHeight': '480',
                  'minFrameRate': '30',
                },
                'facingMode': 'user',
                'optional': [],
              }
            : false,
      };

      _localStream = await navigator.mediaDevices.getUserMedia(mediaConstraints);
      if (_localRenderer != null) {
        _localRenderer!.srcObject = _localStream;
      }

      final configuration = <String, dynamic>{
        'iceServers': iceServers.isNotEmpty
            ? iceServers
            : [
                {
                  'urls': [
                    'stun:remote.grando.app:3478',
                    'turn:remote.grando.app:3478?transport=udp',
                    'turn:remote.grando.app:3478?transport=tcp',
                  ],
                  'username': 'ligament',
                  'credential': 'ligament-secret-turn-key',
                }
              ],
        'sdpSemantics': 'unified-plan',
        'bundlePolicy': 'max-bundle',
      };

      _peerConnection = await createPeerConnection(configuration);

      for (final track in _localStream!.getTracks()) {
        await _peerConnection!.addTrack(track, _localStream!);
      }

      _peerConnection!.onIceCandidate = (candidate) {
        if (candidate.candidate != null && _targetUserId.isNotEmpty) {
          onSendSignal?.call(_targetUserId, _chatId, {
            'type': 'candidate',
            'candidate': {
              'candidate': candidate.candidate,
              'sdpMid': candidate.sdpMid,
              'sdpMLineIndex': candidate.sdpMLineIndex,
            },
          });
        }
      };

      _peerConnection!.onTrack = (event) {
        if (event.streams.isNotEmpty) {
          _remoteStream = event.streams[0];
          if (_remoteRenderer != null) {
            _remoteRenderer!.srcObject = _remoteStream;
          }
          notifyListeners();
        }
      };

      _peerConnection!.onConnectionState = (state) {
        if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
          _status = CallStatus.connected;
          _startDurationTimer();
          notifyListeners();
        } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
            state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
          endCall(notifyPeer: true);
        }
      };

      await _peerConnection!.setRemoteDescription(
        RTCSessionDescription(_pendingOfferSdp, 'offer'),
      );
      _remoteDescriptionSet = true;
      await _flushRemoteCandidates();

      final answer = await _peerConnection!.createAnswer();
      await _peerConnection!.setLocalDescription(answer);

      onSendSignal?.call(_targetUserId, _chatId, {
        'type': 'answer',
        'sdp': answer.sdp,
      });

      _status = CallStatus.connected;
      _startDurationTimer();
      notifyListeners();
    } catch (e) {
      DebugLogService.instance.record('webrtc.accept.failed', error: e);
      endCall(notifyPeer: true);
    }
  }

  /// Отклонить входящий вызов
  void rejectIncomingCall() {
    _ringTimeout?.cancel();
    _ringTimeout = null;
    if (_targetUserId.isNotEmpty) {
      onSendSignal?.call(_targetUserId, _chatId, {'type': 'rejected'});
    }
    endCall(notifyPeer: false);
  }

  /// Получение SDP answer от вызываемого абонента
  Future<void> handleAnswer(String sdp) async {
    if (_peerConnection == null) return;
    try {
      await _peerConnection!.setRemoteDescription(
        RTCSessionDescription(sdp, 'answer'),
      );
      _remoteDescriptionSet = true;
      await _flushRemoteCandidates();
      _ringTimeout?.cancel();
      _ringTimeout = null;
      _status = CallStatus.connected;
      _startDurationTimer();
      notifyListeners();
    } catch (e) {
      DebugLogService.instance.record('webrtc.answer.failed', error: e);
    }
  }

  /// Получение ICE-кандидата
  Future<void> handleRemoteCandidate(Map<String, dynamic> candMap) async {
    final candStr = candMap['candidate'] as String?;
    if (candStr == null || candStr.isEmpty) return;

    final candidate = RTCIceCandidate(
      candStr,
      candMap['sdpMid'] as String? ?? '',
      candMap['sdpMLineIndex'] as int? ?? 0,
    );

    if (_peerConnection != null && _remoteDescriptionSet) {
      try {
        await _peerConnection!.addCandidate(candidate);
      } catch (e) {
        DebugLogService.instance.record('webrtc.candidate.failed', error: e);
      }
    } else {
      _remoteIceCandidateQueue.add(candidate);
    }
  }

  Future<void> _flushRemoteCandidates() async {
    if (_peerConnection == null || !_remoteDescriptionSet) return;
    for (final cand in _remoteIceCandidateQueue) {
      try {
        await _peerConnection!.addCandidate(cand);
      } catch (_) {}
    }
    _remoteIceCandidateQueue.clear();
  }

  void _startDurationTimer() {
    _callTimer?.cancel();
    _durationSeconds = 0;
    _callTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      _durationSeconds++;
      notifyListeners();
    });
  }

  void setPip(bool pip) {
    if (_status == CallStatus.idle) return;
    _displayMode = pip ? CallDisplayMode.pip : CallDisplayMode.fullscreen;
    notifyListeners();
  }

  void toggleMute() {
    _isMuted = !_isMuted;
    if (_localStream != null) {
      for (final track in _localStream!.getAudioTracks()) {
        track.enabled = !_isMuted;
      }
    }
    notifyListeners();
  }

  void toggleCamera() {
    _isCameraOff = !_isCameraOff;
    if (_localStream != null) {
      for (final track in _localStream!.getVideoTracks()) {
        track.enabled = !_isCameraOff;
      }
    }
    notifyListeners();
  }

  void toggleScreenShare() {
    _isScreenSharing = !_isScreenSharing;
    notifyListeners();
  }

  Future<void> switchCamera() async {
    if (_localStream != null) {
      final videoTracks = _localStream!.getVideoTracks();
      if (videoTracks.isNotEmpty) {
        await Helper.switchCamera(videoTracks.first);
        notifyListeners();
      }
    }
  }

  void endCall({bool notifyPeer = true}) {
    _ringTimeout?.cancel();
    _ringTimeout = null;
    _callTimer?.cancel();
    _callTimer = null;

    if (notifyPeer && _targetUserId.isNotEmpty) {
      onSendSignal?.call(_targetUserId, _chatId, {'type': 'hangup'});
    }

    try {
      _localStream?.getTracks().forEach((t) => t.stop());
      _localStream?.dispose();
      _localStream = null;
    } catch (_) {}

    try {
      _remoteStream?.getTracks().forEach((t) => t.stop());
      _remoteStream?.dispose();
      _remoteStream = null;
    } catch (_) {}

    try {
      _peerConnection?.close();
      _peerConnection = null;
    } catch (_) {}

    try {
      _localRenderer?.srcObject = null;
    } catch (_) {}
    try {
      _remoteRenderer?.srcObject = null;
    } catch (_) {}

    _status = CallStatus.idle;
    _displayMode = CallDisplayMode.hidden;
    _chatId = '';
    _chatTitle = '';
    _targetUserId = '';
    _callerName = '';
    _durationSeconds = 0;
    _isScreenSharing = false;
    _remoteDescriptionSet = false;
    _remoteIceCandidateQueue.clear();
    _pendingOfferSdp = '';

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
