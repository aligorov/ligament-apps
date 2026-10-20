import 'dart:async';
import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../models/link_control_messages.dart';
import '../services/auth_state.dart';

class LinkSessionScreen extends StatefulWidget {
  const LinkSessionScreen({
    required this.agentId,
    required this.hostname,
    required this.accessMode,
    super.key,
  });

  final String agentId;
  final String hostname;
  final String accessMode;

  @override
  State<LinkSessionScreen> createState() => _LinkSessionScreenState();
}

class _LinkSessionScreenState extends State<LinkSessionScreen> {
  final RTCVideoRenderer _renderer = RTCVideoRenderer();
  final FocusNode _controlFocus = FocusNode();
  ApiClient? _api;
  List<Map<String, dynamic>> _iceServers = [];
  RTCPeerConnection? _peer;
  RTCDataChannel? _controlChannel;
  Timer? _signalTimer;
  Timer? _heartbeatTimer;
  Timer? _hostAnswerTimer;
  String? _sessionId;
  String? _confirmationCode;
  int _cursor = 0;
  bool _busy = true;
  bool _polling = false;
  bool _stopping = false;
  bool _closeRequested = false;
  bool _remoteDescriptionSet = false;
  bool _controlChannelOpen = false;
  bool _videoFrameRendered = false;
  DateTime? _lastMouseMoveAt;
  String? _error;
  String _status = 'Подключение…';
  final List<Map<String, dynamic>> _queuedCandidates = [];
  final List<Map<String, dynamic>> _pendingRemoteCandidates = [];
  final Map<int, int> _pressedPointerButtons = {};
  final Map<int, LinkKeyMessage> _pressedKeys = {};
  Offset? _lastControlPosition;

  @override
  void initState() {
    super.initState();
    _renderer.onFirstFrameRendered = () {
      if (!mounted || _stopping || _error != null) return;
      setState(() {
        _videoFrameRendered = true;
        _status = _controlChannelOpen
            ? 'Видео отображается; управление готово'
            : 'Видео отображается';
      });
    };
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  Future<void> _start() async {
    final auth = context.read<AuthState>();
    final api = auth.api;
    if (api == null) {
      _fail('Нет активной авторизованной сессии.');
      return;
    }
    _api = api;
    try {
      _iceServers = await api.getLinkIceServers();
      if (!mounted || _stopping) return;
      await _renderer.initialize();
      if (!mounted || _stopping) return;
      final peer = await createPeerConnection({
        'iceServers': _iceServers,
        'sdpSemantics': 'unified-plan',
      });
      _peer = peer;
      if (!mounted || _stopping) {
        await peer.close();
        return;
      }
      await peer.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
      );
      if (widget.accessMode == 'control') {
        final channel = await peer.createDataChannel(
          'link-control-v1',
          RTCDataChannelInit()..ordered = true,
        );
        _controlChannel = channel;
        channel.onDataChannelState = (state) {
          if (!mounted || _stopping) return;
          final open = state == RTCDataChannelState.RTCDataChannelOpen;
          setState(() {
            _controlChannelOpen = open;
            if (open) {
              _status = _videoFrameRendered
                  ? 'Видео отображается; управление готово'
                  : 'Канал управления открыт; ожидание видео';
            } else if (state == RTCDataChannelState.RTCDataChannelClosed) {
              _status = 'Канал управления закрыт';
            }
          });
          if (!open) _clearPressedControlState();
        };
        channel.onMessage = (message) {
          if (message.isBinary) return;
          try {
            final decoded = jsonDecode(message.text);
            if (decoded is Map) {
              _handleControlMessage(Map<String, dynamic>.from(decoded));
            }
          } on FormatException {
            debugPrint('Link control channel received malformed JSON');
          }
        };
      }
      peer.onIceCandidate = (candidate) {
        final value = candidate.toMap();
        if (candidate.candidate == null || candidate.candidate!.isEmpty) return;
        unawaited(_sendSignal({'type': 'candidate', 'candidate': value}));
      };
      peer.onTrack = (event) async {
        MediaStream? stream =
            event.streams.isNotEmpty ? event.streams.first : null;
        if (stream == null) {
          stream = await createLocalMediaStream('link-remote');
          await stream.addTrack(event.track);
        }
        if (!mounted || _stopping) return;
        await _renderer.setSrcObject(stream: stream);
        setState(() => _status = _videoFrameRendered
            ? 'Видео отображается'
            : 'Видеодорожка подключена; ожидание первого кадра');
      };
      peer.onConnectionState = (state) {
        if (!mounted || _stopping) return;
        setState(() {
          _status = switch (state) {
            RTCPeerConnectionState.RTCPeerConnectionStateConnected =>
              _videoFrameRendered
                  ? 'Видео отображается'
                  : 'Соединено; ожидание первого кадра',
            RTCPeerConnectionState.RTCPeerConnectionStateConnecting =>
              'Согласование WebRTC…',
            RTCPeerConnectionState.RTCPeerConnectionStateFailed =>
              'P2P-соединение не установлено',
            RTCPeerConnectionState.RTCPeerConnectionStateDisconnected =>
              'Соединение потеряно',
            _ => state.name,
          };
        });
      };

      final offer = await peer.createOffer();
      await peer.setLocalDescription(offer);
      if (!mounted || _stopping) return;
      final session = await api.requestLinkSession(
        agentId: widget.agentId,
        accessMode: widget.accessMode,
        clientSdp: offer.sdp,
      );
      final id = session['session_id']?.toString();
      if (id == null || id.isEmpty) {
        throw StateError('Сервер не вернул session_id');
      }
      _sessionId = id;
      final confirmationRequired = session['confirmation_required'];
      if (confirmationRequired is! bool) {
        throw StateError(
            'Обновите сервер Ligament: он не поддерживает подтверждение подключения Link.');
      }
      final confirmationCode = session['confirmation_code'];
      if (confirmationRequired) {
        if (confirmationCode is! String ||
            !RegExp(r'^(?:[0-9]{3}|[0-9]{6})$').hasMatch(confirmationCode)) {
          throw StateError(
              'Сервер Link не выдал код подтверждения подключения.');
        }
        _confirmationCode = confirmationCode;
      }
      _hostAnswerTimer?.cancel();
      _hostAnswerTimer = Timer(const Duration(seconds: 120), () {
        if (!_remoteDescriptionSet && mounted && !_stopping) {
          _fail(
              'Хост не ответил за 120 секунд. Проверьте службу Link на компьютере, запрос согласия, разрешение записи экрана и подключение к серверу.');
        }
      });
      if (!mounted || _stopping) {
        _closeRequested = true;
        await api.closeLinkSession(id);
        return;
      }
      if (mounted) {
        setState(() {
          _busy = false;
          _status = _confirmationCode == null
              ? 'Ожидание ответа хоста…'
              : 'Сообщите код пользователю хоста для подтверждения';
        });
      }
      final queued = List<Map<String, dynamic>>.from(_queuedCandidates);
      _queuedCandidates.clear();
      for (final signal in queued) {
        await _sendSignal(signal);
      }
      _signalTimer = Timer.periodic(
        const Duration(milliseconds: 500),
        (_) => unawaited(_pollSignals()),
      );
      _heartbeatTimer = Timer.periodic(
        const Duration(seconds: 20),
        (_) => unawaited(_sendHeartbeat()),
      );
      await _pollSignals();
    } catch (error) {
      _fail('Не удалось начать Link-сессию: $error');
    }
  }

  Future<void> _sendSignal(Map<String, dynamic> signal) async {
    final id = _sessionId;
    if (_stopping) return;
    if (id == null) {
      _queuedCandidates.add(signal);
      return;
    }
    final api = _api;
    if (api == null) return;
    try {
      await api.sendLinkSessionSignal(sessionId: id, signal: signal);
    } catch (error) {
      debugPrint('Link signaling send failed: $error');
    }
  }

  Future<void> _pollSignals() async {
    final id = _sessionId;
    final api = _api;
    if (_polling || _stopping || id == null || api == null) return;
    _polling = true;
    try {
      final result =
          await api.getLinkSessionSignals(sessionId: id, after: _cursor);
      final nextCursor = result['next_cursor'];
      if (nextCursor is int && nextCursor > _cursor) _cursor = nextCursor;
      final rawSignals = result['signals'];
      if (rawSignals is List) {
        for (final raw in rawSignals.whereType<Map>()) {
          await _handleRemoteSignal(Map<String, dynamic>.from(raw));
        }
      }
    } catch (error) {
      debugPrint('Link signaling poll failed: $error');
    } finally {
      _polling = false;
    }
  }

  Future<void> _handleRemoteSignal(Map<String, dynamic> event) async {
    final peer = _peer;
    if (peer == null || _stopping) return;
    final payload = event['payload'];
    if (payload is! Map) return;
    final message = Map<String, dynamic>.from(payload);
    final type = event['type']?.toString() ?? message['type']?.toString();
    if (type == 'session_answer' && !_remoteDescriptionSet) {
      if (message['accepted'] != true) {
        _confirmationCode = null;
        _hostAnswerTimer?.cancel();
        _hostAnswerTimer = null;
        final reason = message['reason']?.toString();
        const rejectionMessages = {
          'number_matching_failed':
              'Код не совпал, уже использован или истёк. Создайте новую сессию.',
          'number_matching_required':
              'Хост не подтвердил код. Обновите приложение хоста и повторите подключение.',
          'host_accessibility_permission_required':
              'На Mac хоста разрешите приложению управление в настройках «Конфиденциальность и безопасность → Универсальный доступ».',
          'host_wayland_control_unavailable':
              'Управление в Wayland не поддерживается. Подключитесь в режиме просмотра или используйте X11.',
          'host_linux_input_unavailable':
              'На Linux-хосте недоступен ввод через X11/xdotool. Проверьте графическую сессию и установку xdotool.',
          'host_screen_capture_unavailable':
              'На хосте недоступен захват экрана. Проверьте разрешение записи экрана и наличие активного рабочего стола.',
        };
        if (rejectionMessages.containsKey(reason)) {
          _fail(rejectionMessages[reason]!);
          return;
        }
        _fail(reason == 'host_worker_unavailable'
            ? 'Служба Link не смогла запустить интерактивный компонент на хосте.'
            : reason == 'host_ready_timeout'
                ? 'Компонент хоста не начал передачу экрана вовремя.'
                : 'Хост отклонил подключение.');
        return;
      }
      final sdp = message['sdp']?.toString();
      if (sdp == null || sdp.isEmpty) {
        _hostAnswerTimer?.cancel();
        _hostAnswerTimer = null;
        _fail('Хост прислал пустой SDP-ответ.');
        return;
      }
      await peer.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
      if (mounted) setState(() => _confirmationCode = null);
      _remoteDescriptionSet = true;
      _hostAnswerTimer?.cancel();
      _hostAnswerTimer = null;
      for (final candidate
          in List<Map<String, dynamic>>.from(_pendingRemoteCandidates)) {
        await _addRemoteCandidate(peer, candidate);
      }
      _pendingRemoteCandidates.clear();
      if (mounted) setState(() => _status = 'WebRTC negotiation…');
      return;
    }
    if (type == 'candidate') {
      final candidateValue = message['candidate'];
      if (candidateValue is Map) {
        final candidate = Map<String, dynamic>.from(candidateValue);
        if (_remoteDescriptionSet) {
          await _addRemoteCandidate(peer, candidate);
        } else if (_pendingRemoteCandidates.length < 256) {
          _pendingRemoteCandidates.add(candidate);
        }
      }
    }
  }

  Future<void> _addRemoteCandidate(
    RTCPeerConnection peer,
    Map<String, dynamic> candidate,
  ) async {
    await peer.addCandidate(RTCIceCandidate(
      candidate['candidate']?.toString(),
      candidate['sdpMid']?.toString(),
      candidate['sdpMLineIndex'] is num
          ? (candidate['sdpMLineIndex'] as num).toInt()
          : null,
    ));
  }

  Future<void> _sendControlMessage(Map<String, Object?> message) async {
    final channel = _controlChannel;
    if (widget.accessMode != 'control' ||
        !_controlChannelOpen ||
        channel == null ||
        _stopping) {
      return;
    }
    try {
      await channel
          .send(RTCDataChannelMessage(encodeLinkControlMessage(message)));
    } catch (error) {
      debugPrint('Link DTLS control send failed: $error');
    }
  }

  void _handleControlMessage(Map<String, dynamic> message) {
    final type = message['type']?.toString();
    if (type == 'session_ended') {
      _fail('Хост завершил сессию.');
    } else if (type == 'input_error' && mounted) {
      setState(() => _status = 'Хост отклонил команду управления');
    }
  }

  Offset? _normalizedPointer(Offset localPosition, {bool release = false}) {
    final renderObject = _videoAreaKey.currentContext?.findRenderObject();
    if (renderObject is! RenderBox) return null;
    final normalized = linkNormalizedPointerPosition(
      position: localPosition,
      viewport: renderObject.size,
      videoWidth: _renderer.videoWidth,
      videoHeight: _renderer.videoHeight,
      clampToVideo: release,
    );
    if (normalized != null) _lastControlPosition = normalized;
    return normalized;
  }

  final GlobalKey _videoAreaKey = GlobalKey();

  int _remoteMouseButton(int buttons) {
    if ((buttons & kPrimaryMouseButton) != 0) return 0;
    if ((buttons & kMiddleMouseButton) != 0) return 1;
    if ((buttons & kSecondaryMouseButton) != 0) return 2;
    return 0;
  }

  void _onPointerMove(PointerEvent event) {
    if (!_controlChannelOpen) return;
    final now = DateTime.now();
    if (_lastMouseMoveAt != null &&
        now.difference(_lastMouseMoveAt!).inMilliseconds < 16) {
      return;
    }
    final position = _normalizedPointer(event.localPosition);
    if (position == null) return;
    _lastMouseMoveAt = now;
    unawaited(_sendControlMessage(linkPointerMessage(
      type: 'mouse_move',
      position: position,
    )));
  }

  void _onPointerDown(PointerDownEvent event) {
    if (!_controlChannelOpen) return;
    _controlFocus.requestFocus();
    final position = _normalizedPointer(event.localPosition);
    if (position == null) return;
    final button = _remoteMouseButton(event.buttons);
    _pressedPointerButtons[event.pointer] = button;
    unawaited(_sendControlMessage(linkPointerMessage(
      type: 'mouse_down',
      position: position,
      button: button,
    )));
  }

  void _onPointerUp(PointerEvent event) {
    final button = _pressedPointerButtons.remove(event.pointer);
    if (button == null || !_controlChannelOpen) return;
    final position = _normalizedPointer(event.localPosition, release: true) ??
        _lastControlPosition ??
        const Offset(0.5, 0.5);
    unawaited(_sendControlMessage(linkPointerMessage(
      type: 'mouse_up',
      position: position,
      button: button,
    )));
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (!_controlChannelOpen || event is! PointerScrollEvent) return;
    unawaited(_sendControlMessage(<String, Object?>{
      'type': 'wheel',
      'deltaY': event.scrollDelta.dy,
    }));
  }

  KeyEventResult _onControlKey(FocusNode node, KeyEvent event) {
    if (!_controlChannelOpen) return KeyEventResult.ignored;
    final key = event.logicalKey.keyLabel;
    if (key.isEmpty) return KeyEventResult.ignored;
    final isDown = event is KeyDownEvent || event is KeyRepeatEvent;
    final message = LinkKeyMessage.tryParse({
      'type': isDown ? 'key_down' : 'key_up',
      'key': key,
      'keyCode': event.logicalKey.keyId,
      'char': event.character,
    });
    if (message == null) return KeyEventResult.ignored;
    var outgoing = message;
    if (isDown) {
      _pressedKeys.putIfAbsent(event.logicalKey.keyId, () => message);
    } else if (event is KeyUpEvent) {
      outgoing =
          _pressedKeys.remove(event.logicalKey.keyId)?.release ?? message;
    } else {
      return KeyEventResult.ignored;
    }
    unawaited(_sendControlMessage(outgoing.toJson()));
    return KeyEventResult.handled;
  }

  void _releasePressedControls() {
    if (!_controlChannelOpen) {
      _clearPressedControlState();
      return;
    }
    final position = _lastControlPosition ?? const Offset(0.5, 0.5);
    for (final button in _pressedPointerButtons.values.toList()) {
      unawaited(_sendControlMessage(linkPointerMessage(
        type: 'mouse_up',
        position: position,
        button: button,
      )));
    }
    for (final key in _pressedKeys.values.toList()) {
      unawaited(_sendControlMessage(key.release.toJson()));
    }
    _clearPressedControlState();
  }

  void _clearPressedControlState() {
    _pressedPointerButtons.clear();
    _pressedKeys.clear();
  }

  Future<void> _sendHeartbeat() async {
    final id = _sessionId;
    final api = _api;
    if (id == null || api == null || _stopping) return;
    try {
      await api.heartbeatLinkSession(id);
    } catch (error) {
      _fail('Сессия Link завершена сервером: $error');
    }
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = message;
      _status = 'Ошибка';
    });
    unawaited(_stop(sendClose: true));
  }

  Future<void> _stop({bool sendClose = false}) async {
    if (_stopping) return;
    _releasePressedControls();
    _stopping = true;
    _hostAnswerTimer?.cancel();
    _signalTimer?.cancel();
    _heartbeatTimer?.cancel();
    final id = _sessionId;
    final api = _api;
    if (sendClose && id != null && api != null && !_closeRequested) {
      _closeRequested = true;
      try {
        await api.closeLinkSession(id);
      } catch (error) {
        debugPrint('Link session close failed: $error');
      }
    }
    final peer = _peer;
    _peer = null;
    final channel = _controlChannel;
    _controlChannel = null;
    if (channel != null) await channel.close();
    if (peer != null) await peer.close();
    await _renderer.setSrcObject(stream: null);
    if (mounted) Navigator.of(context).maybePop();
  }

  @override
  void dispose() {
    final id = _sessionId;
    final api = _api;
    _releasePressedControls();
    if (id != null && api != null && !_closeRequested) {
      _closeRequested = true;
      unawaited(api.closeLinkSession(id).catchError((_) {}));
    }
    _stopping = true;
    _hostAnswerTimer?.cancel();
    _signalTimer?.cancel();
    _heartbeatTimer?.cancel();
    final peer = _peer;
    final channel = _controlChannel;
    _controlChannel = null;
    if (channel != null) unawaited(channel.close());
    if (peer != null) unawaited(peer.close());
    unawaited(_renderer.dispose());
    _controlFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: const Color(0xFF0B0F19),
        appBar: AppBar(
          backgroundColor: const Color(0xFF0B0F19),
          title: Text(widget.hostname),
          actions: [
            IconButton(
              tooltip: 'Завершить сессию',
              onPressed: () => unawaited(_stop(sendClose: true)),
              icon: const Icon(Icons.call_end, color: Color(0xFFF87171)),
            ),
          ],
        ),
        body: Column(
          children: [
            if (_confirmationCode != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: SelectableText('Код подтверждения: $_confirmationCode',
                    key: const Key('link-operator-confirmation-code'),
                    style: const TextStyle(color: Colors.white, fontSize: 24)),
              ),
            Expanded(
              child: ColoredBox(
                color: Colors.black,
                child: Center(
                  child: Focus(
                    focusNode: _controlFocus,
                    canRequestFocus: widget.accessMode == 'control',
                    onKeyEvent: _onControlKey,
                    onFocusChange: (hasFocus) {
                      if (!hasFocus) _releasePressedControls();
                    },
                    child: Listener(
                      key: _videoAreaKey,
                      behavior: HitTestBehavior.opaque,
                      onPointerHover: _onPointerMove,
                      onPointerMove: _onPointerMove,
                      onPointerDown: widget.accessMode == 'control'
                          ? _onPointerDown
                          : null,
                      onPointerUp: _onPointerUp,
                      onPointerCancel: _onPointerUp,
                      onPointerSignal: _onPointerSignal,
                      child: _renderer.srcObject == null
                          ? const Icon(Icons.desktop_windows_outlined,
                              color: Color(0xFF475569), size: 64)
                          : RTCVideoView(
                              _renderer,
                              objectFit: RTCVideoViewObjectFit
                                  .RTCVideoViewObjectFitContain,
                            ),
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  if (_busy)
                    const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  if (_busy) const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _error ?? _status,
                      style: TextStyle(
                        color: _error == null
                            ? const Color(0xFFCBD5E1)
                            : const Color(0xFFFCA5A5),
                      ),
                    ),
                  ),
                  Text(widget.accessMode.toUpperCase(),
                      style: const TextStyle(color: Color(0xFF38BDF8))),
                  if (widget.accessMode == 'control') ...[
                    const SizedBox(width: 8),
                    Icon(
                      _controlChannelOpen ? Icons.lock_open : Icons.lock,
                      size: 16,
                      color: _controlChannelOpen
                          ? const Color(0xFF34D399)
                          : const Color(0xFFFBBF24),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      );
}
