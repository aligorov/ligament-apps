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
  }
  factory CallSessionManager() => instance;

  String _currentCallId = '';
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
      _chatId = chatId;
      _chatTitle = callerName;
      _callerName = callerName;
      _isVideo = isVideo;
      _isCameraOff = !isVideo;
      _status = CallStatus.incoming;
      notifyListeners();
    }
    return _currentCallId;
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

  Future<void> toggleSpeakerphone() async {
    await _audioRoute.toggleSpeaker(isVideo: _isVideo);
    notifyListeners();
  }

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

    _currentCallId = _generateCallId();
    unawaited(CallKitService.instance.startOutgoingCall(
      uuid: _currentCallId,
      recipientName: _callerName,
      hasVideo: isVideo,
    ));

    // Запуск звуковых гудков дозвона (КПВ) в безопасном AudioContext
    unawaited(_sound.startRingback(isVideo: isVideo));

    // Настройка аппаратного аудио-маршрута: видео -> громкая связь, аудио -> ухо
    unawaited(_audioRoute.configureSession(isVideo: isVideo));
    unawaited(_audioRoute.applyRouting(isVideo: isVideo));

    _ringTimeout?.cancel();
    // Стандарт индустрии: 55 секунд дозвона (с учетом Doze mode и push-пробуждения)
    _ringTimeout = Timer(const Duration(seconds: 55), () {
      if (_status == CallStatus.calling || _status == CallStatus.ringing) {
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
        'audio': {
          'echoCancellation': true,
          'noiseSuppression': true,
          'autoGainControl': true,
        },
        'video': isVideo
            ? {
                'mandatory': {},
                'facingMode': 'user',
                'optional': [
                  {'minWidth': 640},
                  {'minHeight': 480},
                  {'minFrameRate': 30},
                ],
              }
            : false,
      };

      _localStream = await navigator.mediaDevices.getUserMedia(mediaConstraints);
      if (_localRenderer != null) {
        try {
          _localRenderer!.srcObject = _localStream;
        } catch (_) {}
      }

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

      final configuration = <String, dynamic>{
        'iceServers': effectiveServers,
        'sdpSemantics': 'unified-plan',
        'bundlePolicy': 'max-bundle',
      };

      _peerConnection = await createPeerConnection(configuration);

      for (final track in _localStream!.getTracks()) {
        await _peerConnection!.addTrack(track, _localStream!);
      }

      _peerConnection!.onIceCandidate = (candidate) {
        _queueOutgoingCandidate(candidate);
      };

      _peerConnection!.onTrack = (event) async {
        MediaStream? stream;
        if (event.streams.isNotEmpty) {
          stream = event.streams[0];
        } else {
          _remoteStream ??= await createLocalMediaStream('remote_stream');
          stream = _remoteStream;
        }

        if (event.track.kind == 'video') {
          if (stream != null && !stream.getVideoTracks().any((t) => t.id == event.track.id)) {
            try {
              await stream.addTrack(event.track);
            } catch (_) {}
          }
          _remoteStream = stream;
          if (_remoteRenderer != null) {
            try {
              _remoteRenderer!.srcObject = null;
              _remoteRenderer!.srcObject = _remoteStream;
            } catch (_) {}
          }
        } else if (event.track.kind == 'audio') {
          if (stream != null && !stream.getAudioTracks().any((t) => t.id == event.track.id)) {
            try {
              await stream.addTrack(event.track);
            } catch (_) {}
          }
          _remoteStream = stream;
          if (_remoteRenderer != null && _remoteRenderer!.srcObject == null) {
            try {
              _remoteRenderer!.srcObject = _remoteStream;
            } catch (_) {}
          }
        }
        notifyListeners();
      };

      _peerConnection!.onIceConnectionState = (state) {
        if (state == RTCIceConnectionState.RTCIceConnectionStateConnected ||
            state == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
          _reconnectTimer?.cancel();
          _reconnectTimer = null;
        } else if (state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
          DebugLogService.instance.record('webrtc.ice.failed');
        }
      };

      _peerConnection!.onConnectionState = (state) {
        if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
          _reconnectTimer?.cancel();
          _reconnectTimer = null;
          _ringTimeout?.cancel();
          _ringTimeout = null;
          unawaited(_sound.stopRingback());
          unawaited(_sound.stopRingtone());
          unawaited(_sound.playConnect());
          try {
            HapticFeedback.mediumImpact();
          } catch (_) {}
          _status = CallStatus.connected;
          if (_currentCallId.isNotEmpty) {
            unawaited(CallKitService.instance.reportConnected(uuid: _currentCallId));
          }
          _startDurationTimer();
          notifyListeners();
        } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
          endCall(notifyPeer: true);
        } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
          // Graceful ICE restart / recovery period (25s) вместо мгновенного разрыва звонка
          if (_status == CallStatus.connected) {
            _reconnectTimer?.cancel();
            _reconnectTimer = Timer(const Duration(seconds: 25), () {
              if (_status != CallStatus.idle) {
                endCall(notifyPeer: true);
              }
            });
            unawaited(performIceRestart());
          } else {
            endCall(notifyPeer: true);
          }
        }
      };

      final offer = await _peerConnection!.createOffer();
      final optimizedSdp = optimizeOpusSdp(offer.sdp ?? '');
      final optimizedOffer = RTCSessionDescription(optimizedSdp, offer.type);
      await _peerConnection!.setLocalDescription(optimizedOffer);
      _localSdp = optimizedSdp;

      onSendSignal?.call(_targetUserId, _chatId, {
        'type': 'offer',
        'sdp': optimizedSdp,
        'is_video': isVideo,
        'caller_name': _callerName,
      });
    } catch (e) {
      DebugLogService.instance.record('webrtc.start.failed', error: e);
    }
  }

  /// Выполняет полноценный ICE Restart с генерацией нового SDP Offer и отправкой пиру
  Future<void> performIceRestart() async {
    if (_peerConnection == null || _status != CallStatus.connected || _isRestartingIce) return;
    _isRestartingIce = true;
    try {
      final offer = await _peerConnection!.createOffer({'iceRestart': true});
      final optimizedSdp = optimizeOpusSdp(offer.sdp ?? '');
      final optimizedOffer = RTCSessionDescription(optimizedSdp, offer.type);
      await _peerConnection!.setLocalDescription(optimizedOffer);
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
    if (sdp.isEmpty || _peerConnection == null) return;
    try {
      _remoteSdp = sdp;
      await _peerConnection!.setRemoteDescription(
        RTCSessionDescription(sdp, 'offer'),
      );
      _remoteDescriptionSet = true;
      await _flushRemoteCandidates();

      final answer = await _peerConnection!.createAnswer();
      final optimizedSdp = optimizeOpusSdp(answer.sdp ?? '');
      final optimizedAnswer = RTCSessionDescription(optimizedSdp, answer.type);
      await _peerConnection!.setLocalDescription(optimizedAnswer);
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

    if (_currentCallId.isEmpty) {
      _currentCallId = _generateCallId();
    }

    // Если пользователь уже ответил с нативного экрана CallKit до получения offer
    if (_pendingAcceptOnOffer) {
      _pendingAcceptOnOffer = false;
      unawaited(acceptIncomingCall());
      return;
    }

    _status = CallStatus.incoming;
    _startRingingAlert();
    unawaited(CallKitService.instance.reportIncomingCall(
      uuid: _currentCallId,
      callerName: _callerName,
      hasVideo: _isVideo,
    ));

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
    if (_pendingOfferSdp.isEmpty) {
      _pendingAcceptOnOffer = true;
      _status = CallStatus.calling;
      notifyListeners();
      return;
    }
    _pendingAcceptOnOffer = false;

    _stopRingingAlert();
    _ringTimeout?.cancel();
    _ringTimeout = null;
    _status = CallStatus.calling;
    notifyListeners();

    // Настройка аудиосессии и маршрута: видео -> громкая связь, аудио -> ухо
    unawaited(_audioRoute.configureSession(isVideo: _isVideo));
    unawaited(_audioRoute.applyRouting(isVideo: _isVideo));

    await initRenderers();

    try {
      final mediaConstraints = <String, dynamic>{
        'audio': {
          'echoCancellation': true,
          'noiseSuppression': true,
          'autoGainControl': true,
        },
        'video': _isVideo
            ? {
                'mandatory': {},
                'facingMode': 'user',
                'optional': [
                  {'minWidth': 640},
                  {'minHeight': 480},
                  {'minFrameRate': 30},
                ],
              }
            : false,
      };

      _localStream = await navigator.mediaDevices.getUserMedia(mediaConstraints);
      if (_localRenderer != null) {
        _localRenderer!.srcObject = _localStream;
      }

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

      final configuration = <String, dynamic>{
        'iceServers': effectiveServers,
        'sdpSemantics': 'unified-plan',
        'bundlePolicy': 'max-bundle',
      };

      _peerConnection = await createPeerConnection(configuration);

      for (final track in _localStream!.getTracks()) {
        await _peerConnection!.addTrack(track, _localStream!);
      }

      _peerConnection!.onIceCandidate = (candidate) {
        _queueOutgoingCandidate(candidate);
      };

      _peerConnection!.onTrack = (event) async {
        MediaStream? stream;
        if (event.streams.isNotEmpty) {
          stream = event.streams[0];
        } else {
          _remoteStream ??= await createLocalMediaStream('remote_stream');
          stream = _remoteStream;
        }

        if (event.track.kind == 'video') {
          if (stream != null && !stream.getVideoTracks().any((t) => t.id == event.track.id)) {
            try {
              await stream.addTrack(event.track);
            } catch (_) {}
          }
          _remoteStream = stream;
          if (_remoteRenderer != null) {
            try {
              _remoteRenderer!.srcObject = null;
              _remoteRenderer!.srcObject = _remoteStream;
            } catch (_) {}
          }
        } else if (event.track.kind == 'audio') {
          if (stream != null && !stream.getAudioTracks().any((t) => t.id == event.track.id)) {
            try {
              await stream.addTrack(event.track);
            } catch (_) {}
          }
          _remoteStream = stream;
          if (_remoteRenderer != null && _remoteRenderer!.srcObject == null) {
            try {
              _remoteRenderer!.srcObject = _remoteStream;
            } catch (_) {}
          }
        }
        notifyListeners();
      };

      _peerConnection!.onIceConnectionState = (state) {
        if (state == RTCIceConnectionState.RTCIceConnectionStateConnected ||
            state == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
          _reconnectTimer?.cancel();
          _reconnectTimer = null;
        } else if (state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
          DebugLogService.instance.record('webrtc.ice.failed');
        }
      };

      _peerConnection!.onConnectionState = (state) {
        if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
          _reconnectTimer?.cancel();
          _reconnectTimer = null;
          _status = CallStatus.connected;
          if (_currentCallId.isNotEmpty) {
            unawaited(CallKitService.instance.reportConnected(uuid: _currentCallId));
          }
          _startDurationTimer();
          unawaited(_sound.stopRingtone());
          unawaited(_sound.playConnect());
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
              if (_status != CallStatus.idle) {
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
      await _peerConnection!.setRemoteDescription(
        RTCSessionDescription(_pendingOfferSdp, 'offer'),
      );
      _remoteDescriptionSet = true;
      await _flushRemoteCandidates();

      final answer = await _peerConnection!.createAnswer();
      final optimizedSdp = optimizeOpusSdp(answer.sdp ?? '');
      final optimizedAnswer = RTCSessionDescription(optimizedSdp, answer.type);
      await _peerConnection!.setLocalDescription(optimizedAnswer);
      _localSdp = optimizedSdp;

      onSendSignal?.call(_targetUserId, _chatId, {
        'type': 'answer',
        'sdp': optimizedSdp,
      });

      _status = CallStatus.calling;
      notifyListeners();
    } catch (e) {
      DebugLogService.instance.record('webrtc.accept.failed', error: e);
      endCall(notifyPeer: true);
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
      unawaited(_sound.startRingback(isVideo: _isVideo));
      notifyListeners();
    }
  }

  /// Абонент не в сети / не подключен к серверу
  void handleOffline() {
    _stopRingingAlert();
    _ringTimeout?.cancel();
    _ringTimeout = null;
    unawaited(_sound.stopRingback());
    unawaited(_sound.playEnd());
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
    unawaited(_sound.playBusy());
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
      unawaited(_sound.playEnd());
    }
    unawaited(_audioRoute.reset());

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
      _remoteRenderer?.srcObject = null;
    } catch (_) {}

    _remoteDescriptionSet = false;
    _remoteIceCandidateQueue.clear();
    _pendingOfferSdp = '';
    _pendingAcceptOnOffer = false;
    _localSdp = '';
    _remoteSdp = '';
    _status = CallStatus.idle;
    _displayMode = CallDisplayMode.fullscreen;
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
    if (_peerConnection == null) return;
    try {
      _remoteSdp = sdp;
      await _peerConnection!.setRemoteDescription(
        RTCSessionDescription(sdp, 'answer'),
      );
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
    if (_peerConnection == null || !_remoteDescriptionSet) return;
    final candidates = List<RTCIceCandidate>.from(_remoteIceCandidateQueue);
    _remoteIceCandidateQueue.clear();
    for (final cand in candidates) {
      try {
        await _peerConnection!.addCandidate(cand);
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

  void endCall({bool notifyPeer = true}) {
    if (_currentCallId.isNotEmpty) {
      unawaited(CallKitService.instance.endCall(uuid: _currentCallId));
      _currentCallId = '';
    }

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
      unawaited(_sound.playEnd());
    }
    unawaited(_audioRoute.reset());

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
    _pendingAcceptOnOffer = false;
    _localSdp = '';
    _remoteSdp = '';

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
