import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'alert_service.dart';
import 'call_audio_route_service.dart';
import 'call_kit_service.dart';
import 'call_sound_player.dart';
import 'debug_log_service.dart';

enum CallStatus {
  idle,
  calling,
  ringing,
  incoming,
  connected,
  offline,
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

  CallSessionManager._() {
    AlertService.instance.onAcceptCall = () {
      acceptIncomingCall();
    };
    AlertService.instance.onDeclineCall = () {
      rejectIncomingCall();
    };

    CallKitService.instance.onCallAccepted = (uuid) {
      acceptIncomingCall();
    };
    CallKitService.instance.onCallEnded = (uuid) {
      if (_status == CallStatus.incoming) {
        rejectIncomingCall();
      } else if (_status != CallStatus.idle) {
        endCall(notifyPeer: true);
      }
    };
    CallKitService.instance.onCallMuted = (muted) {
      if (_isMuted != muted) {
        toggleMute();
      }
    };
    CallKitService.instance.onAudioSessionActivated = () {
      if (_status != CallStatus.idle) {
        unawaited(_audioRoute.configureSession(isVideo: _isVideo));
        unawaited(_audioRoute.applyRouting(isVideo: _isVideo, forceSpeaker: _audioRoute.isSpeaker));
        _enableAudioTracks();
      }
    };
  }
  factory CallSessionManager() => instance;

  String _currentCallId = '';
  bool _callKitReported = false;
  bool _isAcceptingCall = false;
  String get currentCallId => _currentCallId;

  String _generateCallId() {
    final rnd = math.Random.secure();
    final bytes = List<int>.generate(16, (_) => rnd.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // v4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // RFC 4122
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20, 32)}';
  }

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
  Timer? _reconnectTimer;

  final CallAudioRouteService _audioRoute = CallAudioRouteService.instance;
  final CallSoundPlayer _sound = CallSoundPlayer.instance;

  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  MediaStream? _remoteStream;
  final List<RTCIceCandidate> _remoteIceCandidateQueue = [];
  bool _remoteDescriptionSet = false;
  String _pendingOfferSdp = '';

  RTCVideoRenderer? _localRenderer;
  RTCVideoRenderer? _remoteRenderer;
  Future<void>? _initializingRenderers;

  static const List<Map<String, dynamic>> defaultStunServers = [
    {
      'urls': [
        'stun:stun.l.google.com:19302',
        'stun:stun1.l.google.com:19302',
        'stun:stun.cloudflare.com:3478',
      ],
    },
  ];

  bool _pendingAcceptOnOffer = false;
  String _localSdp = '';
  String _remoteSdp = '';
  String get localSdp => _localSdp;
  String get remoteSdp => _remoteSdp;

  @visibleForTesting
  void setSdpForTesting({required String local, required String remote}) {
    _localSdp = local;
    _remoteSdp = remote;
  }

  /// Набор из 12 легко различимых эмодзи для E2E верификации безопасности (SAS fingerprint как в Telegram)
  static const List<String> fingerprintEmojiPalette = [
    '🐱', '🚀', '🍕', '🎸', '🌟', '💎', '🔥', '🏆', '🎯', '⚡', '☕', '🍀',
  ];

  static String? extractDtlsFingerprint(String sdp) {
    if (sdp.isEmpty) return null;
    final match = RegExp(
      r'a=fingerprint:\s*sha-256\s+([0-9a-fA-F:]+)',
      caseSensitive: false,
    ).firstMatch(sdp);
    return match?.group(1)?.trim();
  }

  /// Возвращает 4 эмодзи-верификатора соединения на основе SHA-256 хэша взаимных DTLS-фингерпринтов
  List<String> get callFingerprintEmojis {
    final localFp = extractDtlsFingerprint(_localSdp);
    final remoteFp = extractDtlsFingerprint(_remoteSdp);
    if (localFp == null || remoteFp == null) return const [];

    final sorted = [localFp.toLowerCase(), remoteFp.toLowerCase()]..sort();
    final combined = '${sorted[0]}:${sorted[1]}';
    final hashBytes = sha256.convert(utf8.encode(combined)).bytes;

    return [
      fingerprintEmojiPalette[hashBytes[0] % fingerprintEmojiPalette.length],
      fingerprintEmojiPalette[hashBytes[1] % fingerprintEmojiPalette.length],
      fingerprintEmojiPalette[hashBytes[2] % fingerprintEmojiPalette.length],
      fingerprintEmojiPalette[hashBytes[3] % fingerprintEmojiPalette.length],
    ];
  }

  final List<Map<String, dynamic>> _outgoingCandidateBatch = [];
  Timer? _candidateBatchTimer;
  bool _isRestartingIce = false;

  void _queueOutgoingCandidate(RTCIceCandidate candidate) {
    if (candidate.candidate == null || _targetUserId.isEmpty) return;
    _outgoingCandidateBatch.add({
      'candidate': candidate.candidate,
      'sdpMid': candidate.sdpMid,
      'sdpMLineIndex': candidate.sdpMLineIndex,
    });
    _candidateBatchTimer?.cancel();
    _candidateBatchTimer = Timer(const Duration(milliseconds: 60), _flushOutgoingCandidates);
  }

  void _flushOutgoingCandidates() {
    _candidateBatchTimer?.cancel();
    _candidateBatchTimer = null;
    if (_outgoingCandidateBatch.isEmpty || _targetUserId.isEmpty) return;

    final candidates = List<Map<String, dynamic>>.from(_outgoingCandidateBatch);
    _outgoingCandidateBatch.clear();

    if (candidates.length == 1) {
      onSendSignal?.call(_targetUserId, _chatId, {
        'type': 'candidate',
        'candidate': candidates[0],
      });
    } else {
      onSendSignal?.call(_targetUserId, _chatId, {
        'type': 'candidates',
        'candidates': candidates,
      });
    }
  }

  /// Оптимизация параметров кодека Opus в SDP (In-band Forward Error Correction и DTX)
  /// для устойчивости к потерям пакетов до 25% в нестабильных мобильных сетях.
  static String optimizeOpusSdp(String sdp) {
    if (sdp.isEmpty) return sdp;

    // Находим payload type кодека Opus в SDP (по умолчанию 111)
    final opusPtMatches = RegExp(r'a=rtpmap:(\d+)\s+opus/48000', caseSensitive: false).allMatches(sdp);
    final opusPts = opusPtMatches.map((m) => m.group(1)!).toSet();

    return sdp.replaceAllMapped(
      RegExp(r'(a=fmtp:(\d+)\s+)(.*?)(?=\r\n|\n|$)', caseSensitive: false),
      (match) {
        final prefix = match.group(1)!;
        final pt = match.group(2)!;
        final params = match.group(3)!;

        final isOpus = opusPts.contains(pt) ||
            (opusPts.isEmpty && (params.contains('useinbandfec') || params.contains('minptime')));
        if (!isOpus) return match.group(0)!;

        var updated = params;

        // 1. useinbandfec=1
        if (!updated.contains('useinbandfec=')) {
          updated += ';useinbandfec=1';
        } else if (updated.contains('useinbandfec=0')) {
          updated = updated.replaceAll('useinbandfec=0', 'useinbandfec=1');
        }

        // 2. usedtx=1
        if (!updated.contains('usedtx=')) {
          updated += ';usedtx=1';
        } else if (updated.contains('usedtx=0')) {
          updated = updated.replaceAll('usedtx=0', 'usedtx=1');
        }

        // 3. maxaveragebitrate=24000
        if (!updated.contains('maxaveragebitrate=')) {
          updated += ';maxaveragebitrate=24000';
        }

        // 4. stereo=0
        if (!updated.contains('stereo=')) {
          updated += ';stereo=0';
        }

        return '$prefix$updated';
      },
    );
  }

  /// Подготовка входящего вызова при push-оповещении или CallKit
  String prepareIncomingCall({
    required String chatId,
    required String callerName,
    required bool isVideo,
  }) {
    if (_status == CallStatus.idle) {
      _currentCallId = _generateCallId();
      _callKitReported = false;
      _isAcceptingCall = false;
      _chatId = chatId;
      _chatTitle = callerName;
      _callerName = callerName;
      _isVideo = isVideo;
      _isCameraOff = !isVideo;
      _status = CallStatus.incoming;
      _displayMode = CallDisplayMode.fullscreen;
      _ringTimeout?.cancel();
      _ringTimeout = Timer(const Duration(seconds: 55), () {
        if (_status == CallStatus.incoming) {
          rejectIncomingCall();
        }
      });
      notifyListeners();
    }
    if (!_callKitReported && _currentCallId.isNotEmpty) {
      _callKitReported = true;
      unawaited(CallKitService.instance.reportIncomingCall(
        uuid: _currentCallId,
        callerName: _callerName.isNotEmpty ? _callerName : callerName,
        hasVideo: _isVideo,
      ));
    }
    return _currentCallId;
  }

  void _enableAudioTracks() {
    try {
      if (_localStream != null) {
        for (final t in _localStream!.getAudioTracks()) {
          t.enabled = !_isMuted;
        }
      }
      if (_remoteStream != null) {
        for (final t in _remoteStream!.getAudioTracks()) {
          t.enabled = true;
          unawaited(Helper.setVolume(1.0, t).catchError((_) {}));
        }
      }
    } catch (_) {}
  }

  List<Map<String, dynamic>> _buildEffectiveIceServers(List<Map<String, dynamic>> passedServers) {
    final effectiveServers = List<Map<String, dynamic>>.from(
      passedServers.isNotEmpty ? passedServers : _configuredIceServers,
    );

    final hasStun = effectiveServers.any((s) {
      final urls = s['urls'];
      if (urls is List) {
        return urls.any((u) => u.toString().startsWith('stun:'));
      } else if (urls is String) {
        return urls.startsWith('stun:');
      }
      return false;
    });

    if (!hasStun) {
      effectiveServers.addAll(defaultStunServers);
    }
    return effectiveServers;
  }

  /// Callback для отправки WebRTC сигналинга (offer, answer, candidate, hangup, rejected, busy)
  void Function(String targetUserId, String chatId, Map<String, dynamic> payload)? onSendSignal;

  /// Динамическая конфигурация ICE-серверов с сервера 2FA
  List<Map<String, dynamic>> _configuredIceServers = [];

  void setConfiguredIceServers(List<Map<String, dynamic>> servers) {
    _configuredIceServers = List<Map<String, dynamic>>.from(servers);
  }

  List<Map<String, dynamic>> get configuredIceServers => _configuredIceServers;

  /// Callback для динамического запроса актуальных ICE-серверов у AuthState / 2FA API
  Future<List<Map<String, dynamic>>> Function()? onFetchIceServers;

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

  bool get isSpeakerphoneOn => _audioRoute.isSpeaker;
  bool get isMobileRoutingSupported => _audioRoute.isMobileRoutingSupported;

  bool _isRecorded = false;
  String? _recorderSessionId;
  RTCPeerConnection? _recorderPeerConnection;

  bool get isRecorded => _isRecorded;
  String? get recorderSessionId => _recorderSessionId;

  /// Callback для переключения записи звонка на сервере Ligament Chat
  Future<Map<String, dynamic>> Function(String callId, {required bool record, bool isVideo})? onToggleRecording;

  /// Callback для отправки WebRTC SDP Offer в Recorder (Pion WebRTC Ingest Bot)
  Future<Map<String, dynamic>> Function(String callId, {required String sdp, String? participantId})? onSendRecordOffer;

  Future<void> toggleSpeakerphone() async {
    await _audioRoute.toggleSpeaker(isVideo: _isVideo);
    notifyListeners();
  }

  String get formattedDuration {
    final m = (_durationSeconds ~/ 60).toString().padLeft(2, '0');
    final s = (_durationSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  Future<MediaStream> _acquireUserMedia({required bool wantVideo}) async {
    final audioConstraints = <String, dynamic>{
      'echoCancellation': true,
      'noiseSuppression': true,
      'autoGainControl': true,
    };
    if (wantVideo) {
      try {
        return await navigator.mediaDevices.getUserMedia(<String, dynamic>{
          'audio': audioConstraints,
          'video': {
            'mandatory': {},
            'facingMode': 'user',
            'optional': [
              {'minWidth': 640},
              {'minHeight': 480},
              {'minFrameRate': 30},
            ],
          },
        });
      } catch (e) {
        DebugLogService.instance.record('webrtc.getUserMedia.video_fallback', error: e);
        _isVideo = false;
        _isCameraOff = true;
      }
    }
    return await navigator.mediaDevices.getUserMedia(<String, dynamic>{
      'audio': audioConstraints,
      'video': false,
    });
  }

  void _disposeStreamSafe(MediaStream? stream) {
    if (stream == null) return;
    try {
      for (final t in stream.getTracks()) {
        try {
          t.stop();
        } catch (_) {}
      }
      stream.dispose();
    } catch (_) {}
  }

  /// Старт исходящего вызова
  void startCall({
    required String chatId,
    required String chatTitle,
    required bool isVideo,
    String targetUserId = '',
    List<Map<String, dynamic>> iceServers = const [],
  }) {
    if (_status != CallStatus.idle &&
        _status != CallStatus.ended &&
        _status != CallStatus.offline) {
      return;
    }

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
    _isAcceptingCall = false;
    _audioRoute.prepareDefaultRoute(isVideo: isVideo);

    final callId = _generateCallId();
    _currentCallId = callId;
    unawaited(CallKitService.instance.startOutgoingCall(
      uuid: callId,
      recipientName: _callerName,
      hasVideo: isVideo,
    ));

    _ringTimeout?.cancel();
    // Стандарт индустрии: 55 секунд дозвона (с учетом Doze mode и push-пробуждения)
    _ringTimeout = Timer(const Duration(seconds: 55), () {
      if (_currentCallId == callId &&
          (_status == CallStatus.calling || _status == CallStatus.ringing)) {
        endCall(notifyPeer: true);
      }
    });

    notifyListeners();

    unawaited(_initAndStartWebRTC(
      callId: callId,
      isVideo: isVideo,
      iceServers: iceServers,
    ));
  }

  Future<void> _initAndStartWebRTC({
    required String callId,
    required bool isVideo,
    required List<Map<String, dynamic>> iceServers,
  }) async {
    bool isStillActive() => _status != CallStatus.idle && _currentCallId == callId;

    try {
      final hasPerm = await CallKitService.instance.ensurePermissions(hasVideo: isVideo);
      if (!isStillActive()) return;
      if (!hasPerm) {
        DebugLogService.instance.record('webrtc.start.permission_denied');
        endCall(notifyPeer: false);
        return;
      }

      try {
        await initRenderers();
      } catch (_) {}
      if (!isStillActive()) return;

      await _audioRoute.configureSession(isVideo: _isVideo);
      if (!isStillActive()) return;

      final stream = await _acquireUserMedia(wantVideo: isVideo);
      if (!isStillActive()) {
        _disposeStreamSafe(stream);
        return;
      }
      _localStream = stream;

      if (_localRenderer != null && _localRenderer!.textureId != null) {
        try {
          _localRenderer!.srcObject = _localStream;
        } catch (_) {}
      }

      await _audioRoute.applyRouting(isVideo: _isVideo, forceSpeaker: _audioRoute.isSpeaker);
      if (!isStillActive()) return;

      unawaited(_sound.startRingback(isVideo: _isVideo));

      var effectiveServers = _buildEffectiveIceServers(iceServers);

      if (effectiveServers.length == defaultStunServers.length && onFetchIceServers != null) {
        try {
          final fetched = await onFetchIceServers!();
          if (fetched.isNotEmpty) {
            _configuredIceServers = List<Map<String, dynamic>>.from(fetched);
            effectiveServers = _buildEffectiveIceServers(fetched);
          }
        } catch (_) {}
      }
      if (!isStillActive()) return;

      final configuration = <String, dynamic>{
        'iceServers': effectiveServers,
        'sdpSemantics': 'unified-plan',
        'bundlePolicy': 'max-bundle',
      };

      final pc = await createPeerConnection(configuration);
      if (!isStillActive()) {
        try {
          await pc.close();
        } catch (_) {}
        return;
      }
      _peerConnection = pc;

      for (final track in stream.getTracks()) {
        if (!isStillActive()) return;
        await pc.addTrack(track, stream);
      }
      if (!isStillActive()) return;

      pc.onIceCandidate = (candidate) {
        if (!isStillActive()) return;
        _queueOutgoingCandidate(candidate);
      };

      pc.onTrack = (event) async {
        if (!isStillActive()) return;
        MediaStream? remote;
        if (event.streams.isNotEmpty) {
          remote = event.streams[0];
        } else {
          _remoteStream ??= await createLocalMediaStream('remote_stream');
          remote = _remoteStream;
        }
        if (!isStillActive()) return;

        if (event.track.kind == 'video') {
          if (remote != null && !remote.getVideoTracks().any((t) => t.id == event.track.id)) {
            try {
              await remote.addTrack(event.track);
            } catch (_) {}
          }
          _remoteStream = remote;
          if (_remoteRenderer != null && _remoteRenderer!.textureId != null) {
            try {
              _remoteRenderer!.srcObject = null;
              _remoteRenderer!.srcObject = _remoteStream;
            } catch (_) {}
          }
        } else if (event.track.kind == 'audio') {
          event.track.enabled = true;
          try {
            await Helper.setVolume(1.0, event.track);
          } catch (_) {}
          if (remote != null && !remote.getAudioTracks().any((t) => t.id == event.track.id)) {
            try {
              await remote.addTrack(event.track);
            } catch (_) {}
          }
          _remoteStream = remote;
          if (_remoteRenderer != null &&
              _remoteRenderer!.textureId != null &&
              _remoteRenderer!.srcObject == null) {
            try {
              _remoteRenderer!.srcObject = _remoteStream;
            } catch (_) {}
          }
          unawaited(_audioRoute.applyRouting(isVideo: _isVideo, forceSpeaker: _audioRoute.isSpeaker));
        }
        notifyListeners();
      };

      pc.onIceConnectionState = (state) {
        if (!isStillActive()) return;
        if (state == RTCIceConnectionState.RTCIceConnectionStateConnected ||
            state == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
          _reconnectTimer?.cancel();
          _reconnectTimer = null;
        } else if (state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
          DebugLogService.instance.record('webrtc.ice.failed');
        }
      };

      pc.onConnectionState = (state) {
        if (!isStillActive()) return;
        if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
          _reconnectTimer?.cancel();
          _reconnectTimer = null;
          _ringTimeout?.cancel();
          _ringTimeout = null;
          unawaited(_sound.stopRingback());
          unawaited(_sound.stopRingtone());
          unawaited(CallKitService.instance.activateAudio(hasVideo: _isVideo));
          unawaited(_audioRoute.configureSession(isVideo: _isVideo));
          unawaited(_audioRoute.applyRouting(isVideo: _isVideo, forceSpeaker: _audioRoute.isSpeaker));
          _enableAudioTracks();
          unawaited(_sound.playConnect(isVideo: _isVideo));
          try {
            HapticFeedback.mediumImpact();
          } catch (_) {}
          _status = CallStatus.connected;
          if (_currentCallId.isNotEmpty) {
            unawaited(CallKitService.instance.reportConnected(uuid: _currentCallId));
          }
          _startDurationTimer();
          if (_isRecorded) {
            unawaited(_startRecordingPeer());
          }
          notifyListeners();
        } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
          endCall(notifyPeer: true);
        } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
          if (_status == CallStatus.connected) {
            _reconnectTimer?.cancel();
            _reconnectTimer = Timer(const Duration(seconds: 25), () {
              if (isStillActive()) {
                endCall(notifyPeer: true);
              }
            });
            unawaited(performIceRestart());
          } else {
            endCall(notifyPeer: true);
          }
        }
      };

      final offer = await pc.createOffer();
      if (!isStillActive()) return;
      final optimizedSdp = optimizeOpusSdp(offer.sdp ?? '');
      final optimizedOffer = RTCSessionDescription(optimizedSdp, offer.type);
      await pc.setLocalDescription(optimizedOffer);
      if (!isStillActive()) return;
      _localSdp = optimizedSdp;

      onSendSignal?.call(_targetUserId, _chatId, {
        'type': 'offer',
        'call_id': callId,
        'sdp': optimizedSdp,
        'is_video': _isVideo,
        'caller_name': _callerName,
      });
    } catch (e) {
      DebugLogService.instance.record('webrtc.start.failed', error: e);
      if (isStillActive()) {
        endCall(notifyPeer: true);
      }
    }
  }

  /// Выполняет полноценный ICE Restart с генерацией нового SDP Offer и отправкой пиру
  Future<void> performIceRestart() async {
    final pc = _peerConnection;
    if (pc == null || _status != CallStatus.connected || _isRestartingIce) return;
    _isRestartingIce = true;
    try {
      final offer = await pc.createOffer({'iceRestart': true});
      if (_peerConnection != pc || _status != CallStatus.connected) return;
      final optimizedSdp = optimizeOpusSdp(offer.sdp ?? '');
      final optimizedOffer = RTCSessionDescription(optimizedSdp, offer.type);
      await pc.setLocalDescription(optimizedOffer);
      _localSdp = optimizedSdp;

      if (_targetUserId.isNotEmpty) {
        onSendSignal?.call(_targetUserId, _chatId, {
          'type': 'offer',
          'sdp': optimizedSdp,
          'ice_restart': true,
          'caller_name': _callerName,
          'is_video': _isVideo,
        });
      }
    } catch (e) {
      DebugLogService.instance.record('webrtc.ice_restart.failed', error: e);
    } finally {
      _isRestartingIce = false;
    }
  }

  /// Обработка renegotiation / ICE restart оффера во время активного соединения
  Future<void> _handleOfferRenegotiation(Map<String, dynamic> offerPayload) async {
    final sdp = offerPayload['sdp'] as String? ?? '';
    final pc = _peerConnection;
    if (sdp.isEmpty || pc == null) return;
    try {
      _remoteSdp = sdp;
      await pc.setRemoteDescription(
        RTCSessionDescription(sdp, 'offer'),
      );
      if (_peerConnection != pc) return;
      _remoteDescriptionSet = true;
      await _flushRemoteCandidates();

      final answer = await pc.createAnswer();
      if (_peerConnection != pc) return;
      final optimizedSdp = optimizeOpusSdp(answer.sdp ?? '');
      final optimizedAnswer = RTCSessionDescription(optimizedSdp, answer.type);
      await pc.setLocalDescription(optimizedAnswer);
      _localSdp = optimizedSdp;

      if (_targetUserId.isNotEmpty) {
        onSendSignal?.call(_targetUserId, _chatId, {
          'type': 'answer',
          'sdp': optimizedSdp,
          'ice_restart': true,
        });
      }
    } catch (e) {
      DebugLogService.instance.record('webrtc.renegotiation.failed', error: e);
    }
  }

  void _startRingingAlert() {
    try {
      AlertService.instance.triggerIncomingCallNotification(
        caller: _callerName,
        isVideo: _isVideo,
        chatId: _chatId,
      ).catchError((_) {});
    } catch (_) {}
    if (kIsWeb ||
        (defaultTargetPlatform != TargetPlatform.iOS &&
            defaultTargetPlatform != TargetPlatform.android)) {
      unawaited(_sound.startRingtone());
    }
  }

  void _stopRingingAlert() {
    unawaited(_sound.stopRingtone());
    try {
      AlertService.instance.resetWindowPriority().catchError((_) {});
    } catch (_) {}
  }

  /// Обработка входящего вызова (offer)
  void handleIncomingOffer({
    required String fromUser,
    required String chatId,
    required Map<String, dynamic> offerPayload,
  }) {
    if (_status != CallStatus.idle && _status != CallStatus.incoming && _status != CallStatus.calling) {
      if (_status == CallStatus.connected && (_targetUserId == fromUser || offerPayload['ice_restart'] == true)) {
        // Это renegotiation / ICE restart в рамках активного звонка
        unawaited(_handleOfferRenegotiation(offerPayload));
        return;
      }
      onSendSignal?.call(fromUser, chatId, {'type': 'busy', 'device_busy': true});
      return;
    }

    // Сообщаем звонящему, что вызов доставлен и играет рингтон
    onSendSignal?.call(fromUser, chatId, {'type': 'ringing'});

    _chatId = chatId;
    _targetUserId = fromUser;
    final caller = offerPayload['caller_name'] as String?;
    _callerName = (caller != null && caller.trim().isNotEmpty) ? caller.trim() : fromUser;
    _chatTitle = _callerName;
    _isVideo = offerPayload['is_video'] == true ||
        offerPayload['is_video'] == 'true' ||
        offerPayload['is_video'] == 1;
    _isMuted = false;
    _isCameraOff = !_isVideo;
    _isScreenSharing = false;
    _displayMode = CallDisplayMode.fullscreen;
    _pendingOfferSdp = offerPayload['sdp'] as String? ?? '';
    _remoteDescriptionSet = false;
    _remoteIceCandidateQueue.clear();

    final incomingCallId = offerPayload['call_id'] as String?;
    if (incomingCallId != null && incomingCallId.isNotEmpty) {
      _currentCallId = incomingCallId;
    } else if (_currentCallId.isEmpty) {
      _currentCallId = _generateCallId();
      _callKitReported = false;
      _isAcceptingCall = false;
    }

    // Если пользователь уже ответил с нативного экрана CallKit до получения offer
    if (_pendingAcceptOnOffer) {
      _pendingAcceptOnOffer = false;
      unawaited(acceptIncomingCall());
      return;
    }

    _status = CallStatus.incoming;
    _startRingingAlert();
    if (!_callKitReported) {
      _callKitReported = true;
      unawaited(CallKitService.instance.reportIncomingCall(
        uuid: _currentCallId,
        callerName: _callerName,
        hasVideo: _isVideo,
      ));
    }

    _ringTimeout?.cancel();
    _ringTimeout = Timer(const Duration(seconds: 55), () {
      if (_status == CallStatus.incoming) {
        rejectIncomingCall();
      }
    });

    notifyListeners();
  }

  /// Принять входящий вызов
  Future<void> acceptIncomingCall({List<Map<String, dynamic>> iceServers = const []}) async {
    if (_isAcceptingCall || _status == CallStatus.connected || _status == CallStatus.idle) {
      return;
    }

    if (_currentCallId.isNotEmpty) {
      unawaited(CallKitService.instance.answerCall(uuid: _currentCallId, hasVideo: _isVideo));
    }
    unawaited(CallKitService.instance.activateAudio(hasVideo: _isVideo));

    if (_pendingOfferSdp.isEmpty) {
      _pendingAcceptOnOffer = true;
      _status = CallStatus.calling;
      notifyListeners();
      return;
    }
    _pendingAcceptOnOffer = false;
    _isAcceptingCall = true;

    final callId = _currentCallId;
    bool isStillActive() => _status != CallStatus.idle && _currentCallId == callId;

    _stopRingingAlert();
    _ringTimeout?.cancel();
    _ringTimeout = null;
    _status = CallStatus.calling;
    _audioRoute.prepareDefaultRoute(isVideo: _isVideo);
    notifyListeners();

    try {
      final hasPerm = await CallKitService.instance.ensurePermissions(hasVideo: _isVideo);
      if (!isStillActive()) return;
      if (!hasPerm) {
        DebugLogService.instance.record('webrtc.accept.permission_denied');
        rejectIncomingCall();
        return;
      }

      try {
        await initRenderers();
      } catch (_) {}
      if (!isStillActive()) return;

      await _audioRoute.configureSession(isVideo: _isVideo);
      if (!isStillActive()) return;

      final stream = await _acquireUserMedia(wantVideo: _isVideo);
      if (!isStillActive()) {
        _disposeStreamSafe(stream);
        return;
      }
      _localStream = stream;

      if (_localRenderer != null && _localRenderer!.textureId != null) {
        try {
          _localRenderer!.srcObject = _localStream;
        } catch (_) {}
      }

      await _audioRoute.applyRouting(isVideo: _isVideo, forceSpeaker: _audioRoute.isSpeaker);
      if (!isStillActive()) return;

      var effectiveServers = _buildEffectiveIceServers(iceServers);

      if (effectiveServers.length == defaultStunServers.length && onFetchIceServers != null) {
        try {
          final fetched = await onFetchIceServers!();
          if (fetched.isNotEmpty) {
            _configuredIceServers = List<Map<String, dynamic>>.from(fetched);
            effectiveServers = _buildEffectiveIceServers(fetched);
          }
        } catch (_) {}
      }
      if (!isStillActive()) return;

      final configuration = <String, dynamic>{
        'iceServers': effectiveServers,
        'sdpSemantics': 'unified-plan',
        'bundlePolicy': 'max-bundle',
      };

      final pc = await createPeerConnection(configuration);
      if (!isStillActive()) {
        try {
          await pc.close();
        } catch (_) {}
        return;
      }
      _peerConnection = pc;

      for (final track in stream.getTracks()) {
        if (!isStillActive()) return;
        await pc.addTrack(track, stream);
      }
      if (!isStillActive()) return;

      pc.onIceCandidate = (candidate) {
        if (!isStillActive()) return;
        _queueOutgoingCandidate(candidate);
      };

      pc.onTrack = (event) async {
        if (!isStillActive()) return;
        MediaStream? remote;
        if (event.streams.isNotEmpty) {
          remote = event.streams[0];
        } else {
          _remoteStream ??= await createLocalMediaStream('remote_stream');
          remote = _remoteStream;
        }
        if (!isStillActive()) return;

        if (event.track.kind == 'video') {
          if (remote != null && !remote.getVideoTracks().any((t) => t.id == event.track.id)) {
            try {
              await remote.addTrack(event.track);
            } catch (_) {}
          }
          _remoteStream = remote;
          if (_remoteRenderer != null && _remoteRenderer!.textureId != null) {
            try {
              _remoteRenderer!.srcObject = null;
              _remoteRenderer!.srcObject = _remoteStream;
            } catch (_) {}
          }
        } else if (event.track.kind == 'audio') {
          event.track.enabled = true;
          try {
            await Helper.setVolume(1.0, event.track);
          } catch (_) {}
          if (remote != null && !remote.getAudioTracks().any((t) => t.id == event.track.id)) {
            try {
              await remote.addTrack(event.track);
            } catch (_) {}
          }
          _remoteStream = remote;
          if (_remoteRenderer != null &&
              _remoteRenderer!.textureId != null &&
              _remoteRenderer!.srcObject == null) {
            try {
              _remoteRenderer!.srcObject = _remoteStream;
            } catch (_) {}
          }
          unawaited(_audioRoute.applyRouting(isVideo: _isVideo, forceSpeaker: _audioRoute.isSpeaker));
        }
        notifyListeners();
      };

      pc.onIceConnectionState = (state) {
        if (!isStillActive()) return;
        if (state == RTCIceConnectionState.RTCIceConnectionStateConnected ||
            state == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
          _reconnectTimer?.cancel();
          _reconnectTimer = null;
        } else if (state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
          DebugLogService.instance.record('webrtc.ice.failed');
        }
      };

      pc.onConnectionState = (state) {
        if (!isStillActive()) return;
        if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
          _reconnectTimer?.cancel();
          _reconnectTimer = null;
          _status = CallStatus.connected;
          if (_currentCallId.isNotEmpty) {
            unawaited(CallKitService.instance.reportConnected(uuid: _currentCallId));
          }
          _startDurationTimer();
          if (_isRecorded) {
            unawaited(_startRecordingPeer());
          }
          unawaited(_sound.stopRingtone());
          unawaited(CallKitService.instance.activateAudio(hasVideo: _isVideo));
          unawaited(_audioRoute.configureSession(isVideo: _isVideo));
          unawaited(_audioRoute.applyRouting(isVideo: _isVideo, forceSpeaker: _audioRoute.isSpeaker));
          _enableAudioTracks();
          unawaited(_sound.playConnect(isVideo: _isVideo));
          try {
            HapticFeedback.mediumImpact();
          } catch (_) {}
          notifyListeners();
        } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
          endCall(notifyPeer: true);
        } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
          if (_status == CallStatus.connected) {
            _reconnectTimer?.cancel();
            _reconnectTimer = Timer(const Duration(seconds: 25), () {
              if (isStillActive()) {
                endCall(notifyPeer: true);
              }
            });
            unawaited(performIceRestart());
          } else {
            endCall(notifyPeer: true);
          }
        }
      };

      _remoteSdp = _pendingOfferSdp;
      await pc.setRemoteDescription(
        RTCSessionDescription(_pendingOfferSdp, 'offer'),
      );
      if (!isStillActive()) return;
      _remoteDescriptionSet = true;
      await _flushRemoteCandidates();
      if (!isStillActive()) return;

      final answer = await pc.createAnswer();
      if (!isStillActive()) return;
      final optimizedSdp = optimizeOpusSdp(answer.sdp ?? '');
      final optimizedAnswer = RTCSessionDescription(optimizedSdp, answer.type);
      await pc.setLocalDescription(optimizedAnswer);
      if (!isStillActive()) return;
      _localSdp = optimizedSdp;

      onSendSignal?.call(_targetUserId, _chatId, {
        'type': 'answer',
        'sdp': optimizedSdp,
      });

      if (_status != CallStatus.connected) {
        _status = CallStatus.calling;
      }
      notifyListeners();
    } catch (e) {
      DebugLogService.instance.record('webrtc.accept.failed', error: e);
      if (isStillActive()) {
        endCall(notifyPeer: true);
      }
    } finally {
      _isAcceptingCall = false;
    }
  }

  /// Отклонить входящий вызов
  void rejectIncomingCall() {
    if (_currentCallId.isNotEmpty) {
      unawaited(CallKitService.instance.endCall(uuid: _currentCallId));
    }
    _stopRingingAlert();
    _ringTimeout?.cancel();
    _ringTimeout = null;
    if (_targetUserId.isNotEmpty) {
      onSendSignal?.call(_targetUserId, _chatId, {'type': 'rejected'});
    }
    endCall(notifyPeer: false);
  }

  /// Подтверждение доставки вызова (абонент найден, на устройстве идут гудки)
  void handleRinging() {
    if (_status == CallStatus.calling) {
      _status = CallStatus.ringing;
      notifyListeners();
    }
  }

  /// Абонент не в сети / не подключен к серверу
  void handleOffline() {
    _stopRingingAlert();
    _ringTimeout?.cancel();
    _ringTimeout = null;
    unawaited(_sound.stopRingback());
    unawaited(_sound.playEnd(isVideo: _isVideo));
    _status = CallStatus.offline;
    notifyListeners();
    Timer(const Duration(seconds: 3), () {
      if (_status == CallStatus.offline) {
        endCall(notifyPeer: false);
      }
    });
  }

  /// Абонент занят
  void handleBusy() {
    _stopRingingAlert();
    _ringTimeout?.cancel();
    _ringTimeout = null;
    unawaited(_sound.stopRingback());
    unawaited(_sound.playBusy(isVideo: _isVideo));
    try {
      HapticFeedback.heavyImpact();
    } catch (_) {}
    _status = CallStatus.ended;
    notifyListeners();
    Timer(const Duration(milliseconds: 2500), () {
      endCall(notifyPeer: false);
    });
  }

  /// Отмена входящего вызова (отменено звонящим, таймаут, либо отвечено на другом устройстве)
  void handleCancel({String reason = ''}) {
    if (_currentCallId.isNotEmpty) {
      unawaited(CallKitService.instance.endCall(uuid: _currentCallId));
      _currentCallId = '';
    }
    _callKitReported = false;
    _isAcceptingCall = false;

    final wasActive = _status == CallStatus.connected ||
        _status == CallStatus.calling ||
        _status == CallStatus.ringing;

    _stopRingingAlert();
    _ringTimeout?.cancel();
    _ringTimeout = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _callTimer?.cancel();
    _callTimer = null;
    _candidateBatchTimer?.cancel();
    _candidateBatchTimer = null;
    _outgoingCandidateBatch.clear();
    _isRestartingIce = false;

    unawaited(_sound.stopRingback());
    unawaited(_sound.stopRingtone());
    if (wasActive && reason != 'answered_elsewhere') {
      unawaited(_sound.playEnd(isVideo: _isVideo));
    }
    unawaited(_audioRoute.reset());

    _disposeStreamSafe(_localStream);
    _localStream = null;

    _disposeStreamSafe(_remoteStream);
    _remoteStream = null;

    try {
      _peerConnection?.close();
      _peerConnection = null;
    } catch (_) {}

    try {
      if (_localRenderer != null && _localRenderer!.textureId != null) {
        _localRenderer!.srcObject = null;
      }
    } catch (_) {}
    try {
      if (_remoteRenderer != null && _remoteRenderer!.textureId != null) {
        _remoteRenderer!.srcObject = null;
      }
    } catch (_) {}

    _remoteDescriptionSet = false;
    _remoteIceCandidateQueue.clear();
    _pendingOfferSdp = '';
    _pendingAcceptOnOffer = false;
    _localSdp = '';
    _remoteSdp = '';
    _status = CallStatus.idle;
    _displayMode = CallDisplayMode.hidden;
    _targetUserId = '';
    _chatId = '';
    _chatTitle = '';
    _callerName = '';
    _durationSeconds = 0;
    _isMuted = false;
    _isCameraOff = false;
    _isScreenSharing = false;
    notifyListeners();
  }

  /// Получение SDP answer от вызываемого абонента
  Future<void> handleAnswer(String sdp) async {
    final pc = _peerConnection;
    if (pc == null) return;
    try {
      _remoteSdp = sdp;
      await pc.setRemoteDescription(
        RTCSessionDescription(sdp, 'answer'),
      );
      if (_peerConnection != pc) return;
      _remoteDescriptionSet = true;
      await _flushRemoteCandidates();
      _ringTimeout?.cancel();
      _ringTimeout = null;
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
      unawaited(_sound.stopRingback());
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
      (candMap['sdpMLineIndex'] as num?)?.toInt() ?? 0,
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
    final pc = _peerConnection;
    if (pc == null || !_remoteDescriptionSet) return;
    final candidates = List<RTCIceCandidate>.from(_remoteIceCandidateQueue);
    _remoteIceCandidateQueue.clear();
    for (final cand in candidates) {
      if (_peerConnection != pc) return;
      try {
        await pc.addCandidate(cand);
      } catch (_) {}
    }
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
    if (_currentCallId.isNotEmpty) {
      unawaited(CallKitService.instance.setMuted(uuid: _currentCallId, muted: _isMuted));
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

  /// Переключение записи активного разговора
  Future<void> toggleRecording() async {
    if (_currentCallId.isEmpty || onToggleRecording == null) return;
    try {
      await onToggleRecording!(_currentCallId, record: !_isRecorded, isVideo: _isVideo);
    } catch (e) {
      DebugLogService.instance.record('call.recording.toggle_failed', error: e);
    }
  }

  /// Обработка события call.recording от сервера
  void handleRecordingState({required bool isRecorded, String? recorderSessionId}) {
    _isRecorded = isRecorded;
    if (recorderSessionId != null && recorderSessionId.isNotEmpty) {
      _recorderSessionId = recorderSessionId;
    } else {
      _recorderSessionId ??= _currentCallId;
    }
    notifyListeners();

    if (_isRecorded && _status == CallStatus.connected) {
      unawaited(_startRecordingPeer());
    } else if (!_isRecorded) {
      unawaited(_stopRecordingPeer());
    }
  }

  Future<void> _startRecordingPeer() async {
    if (_recorderPeerConnection != null || _localStream == null || onSendRecordOffer == null) {
      return;
    }
    final sessId = _recorderSessionId ?? _currentCallId;
    if (sessId.isEmpty) return;

    final audioTracks = _localStream!.getAudioTracks();
    if (audioTracks.isEmpty) return;

    try {
      final pc = await createPeerConnection({
        'iceServers': defaultStunServers,
        'bundlePolicy': 'max-bundle',
      });
      _recorderPeerConnection = pc;

      for (final track in audioTracks) {
        await pc.addTrack(track, _localStream!);
      }

      final offer = await pc.createOffer();
      final optimizedSdp = optimizeOpusSdp(offer.sdp ?? '');
      final optimizedOffer = RTCSessionDescription(optimizedSdp, offer.type);
      await pc.setLocalDescription(optimizedOffer);

      final completer = Completer<void>();
      Timer? timeoutTimer;
      pc.onIceGatheringState = (state) {
        if (state == RTCIceGatheringState.RTCIceGatheringStateComplete) {
          timeoutTimer?.cancel();
          if (!completer.isCompleted) completer.complete();
        }
      };
      timeoutTimer = Timer(const Duration(milliseconds: 1500), () {
        if (!completer.isCompleted) completer.complete();
      });
      await completer.future;

      final localDesc = await pc.getLocalDescription();
      final sdpToSend = localDesc?.sdp ?? optimizedSdp;

      final resp = await onSendRecordOffer!(sessId, sdp: sdpToSend);
      final answerSdp = resp['sdp'] as String?;
      if (answerSdp != null && answerSdp.isNotEmpty && _recorderPeerConnection == pc) {
        await pc.setRemoteDescription(RTCSessionDescription(answerSdp, 'answer'));
        DebugLogService.instance.record('call.recording.peer_connected', fields: {'session_id': sessId});
      }
    } catch (e) {
      DebugLogService.instance.record('call.recording.start_failed', error: e);
      await _stopRecordingPeer();
    }
  }

  Future<void> _stopRecordingPeer() async {
    final pc = _recorderPeerConnection;
    _recorderPeerConnection = null;
    if (pc != null) {
      try {
        await pc.close();
      } catch (_) {}
    }
  }

  void endCall({bool notifyPeer = true}) {
    unawaited(_stopRecordingPeer());
    _isRecorded = false;
    _recorderSessionId = null;
    if (_currentCallId.isNotEmpty) {
      unawaited(CallKitService.instance.endCall(uuid: _currentCallId));
      _currentCallId = '';
    }
    _callKitReported = false;
    _isAcceptingCall = false;

    final wasActive = _status == CallStatus.connected ||
        _status == CallStatus.calling ||
        _status == CallStatus.ringing;

    _stopRingingAlert();
    _ringTimeout?.cancel();
    _ringTimeout = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _callTimer?.cancel();
    _callTimer = null;
    _candidateBatchTimer?.cancel();
    _candidateBatchTimer = null;
    _outgoingCandidateBatch.clear();
    _isRestartingIce = false;

    unawaited(_sound.stopRingback());
    unawaited(_sound.stopRingtone());
    if (wasActive) {
      unawaited(_sound.playEnd(isVideo: _isVideo));
    }
    unawaited(_audioRoute.reset());

    if (notifyPeer && _targetUserId.isNotEmpty) {
      onSendSignal?.call(_targetUserId, _chatId, {'type': 'hangup'});
    }

    _disposeStreamSafe(_localStream);
    _localStream = null;

    _disposeStreamSafe(_remoteStream);
    _remoteStream = null;

    try {
      _peerConnection?.close();
      _peerConnection = null;
    } catch (_) {}

    try {
      if (_localRenderer != null && _localRenderer!.textureId != null) {
        _localRenderer!.srcObject = null;
      }
    } catch (_) {}
    try {
      if (_remoteRenderer != null && _remoteRenderer!.textureId != null) {
        _remoteRenderer!.srcObject = null;
      }
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
    _pendingAcceptOnOffer = false;
    _localSdp = '';
    _remoteSdp = '';

    notifyListeners();
  }

  Future<void> initRenderers() async {
    if (_localRenderer != null &&
        _localRenderer!.textureId != null &&
        _remoteRenderer != null &&
        _remoteRenderer!.textureId != null) {
      return;
    }
    if (_initializingRenderers != null) {
      await _initializingRenderers;
      return;
    }
    final completer = Completer<void>();
    _initializingRenderers = completer.future;
    try {
      if (_localRenderer == null || _localRenderer!.textureId == null) {
        final local = RTCVideoRenderer();
        await local.initialize();
        _localRenderer = local;
      }
      if (_remoteRenderer == null || _remoteRenderer!.textureId == null) {
        final remote = RTCVideoRenderer();
        await remote.initialize();
        _remoteRenderer = remote;
      }
      notifyListeners();
    } finally {
      _initializingRenderers = null;
      if (!completer.isCompleted) {
        completer.complete();
      }
    }
  }

  Future<void> disposeRenderers() async {
    final local = _localRenderer;
    _localRenderer = null;
    if (local != null) {
      try {
        if (local.textureId != null) {
          local.srcObject = null;
        }
        await local.dispose();
      } catch (_) {}
    }

    final remote = _remoteRenderer;
    _remoteRenderer = null;
    if (remote != null) {
      try {
        if (remote.textureId != null) {
          remote.srcObject = null;
        }
        await remote.dispose();
      } catch (_) {}
    }
  }
}
