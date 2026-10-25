import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'input_injector.dart';
import 'link_host_readiness.dart';
import 'link_host_recorder.dart';
import 'support_service.dart'
    show SupportChatMessage, assembleFileChunks, resolveNonCollidingFilePath;
import '../models/link_control_messages.dart';
import '../models/link_session_policy.dart';

typedef LinkHostSignalSender = Future<void> Function(
  Map<String, dynamic> frame,
);

abstract interface class LinkHostPeer {
  Future<String> start({
    required String offerSdp,
    required List<Map<String, dynamic>> iceServers,
    required bool allowControl,
    required void Function(Map<String, dynamic>) onCandidate,
    required void Function() onFailure,
  });

  Future<String> renegotiateOffer(String offerSdp);
  Future<void> addRemoteCandidate(Map<String, dynamic> candidate);
  Future<void> close();
}

/// Owns one server-authorized Link session. It translates the WSS agent
/// protocol to a WebRTC peer without sharing the legacy Support signaling API.
class LinkHostSession {
  static bool isValidControlInput(Map<String, dynamic> input) =>
      FlutterLinkHostPeer.isValidInput(input);

  LinkHostSession({
    required this.sessionId,
    required this.accessMode,
    required this.peer,
    required this.send,
    this.readyTimeout = const Duration(seconds: 45),
  }) {
    if (!_uuid.hasMatch(sessionId)) {
      throw const FormatException('Invalid Link session ID');
    }
    if (accessMode != 'view' && accessMode != 'control') {
      throw const FormatException('Invalid Link access mode');
    }
  }

  static final _uuid = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
    caseSensitive: false,
  );
  static const maxOfferSdpBytes = 256 * 1024;
  static const maxIceServers = 32;
  static const maxPendingCandidates = 256;
  static const _nativeChannel = MethodChannel('ligament/link_host');

  final String sessionId;
  final String accessMode;
  final LinkHostPeer peer;
  final LinkHostSignalSender send;
  final Duration readyTimeout;

  final List<Map<String, dynamic>> _pendingCandidates = [];
  Timer? _readyTimer;
  bool _started = false;
  Completer<bool>? _authorization;
  String? _consentNonce;
  bool _ready = false;
  bool _closed = false;
  Future<void>? _closing;
  Future<void>? _rejecting;
  final Completer<void> _done = Completer<void>();

  bool get isClosed => _closed;
  Future<void> get done => _done.future;

  Future<void> start({
    required String offerSdp,
    required List<Map<String, dynamic>> iceServers,
    bool consentGranted = false,
    bool confirmationRequired = false,
    String confirmationCode = '',
  }) async {
    if (_started || _closed) {
      throw StateError('Link host session already started or closed');
    }
    _started = true;
    _readyTimer = Timer(readyTimeout, () {
      unawaited(_reject('host_ready_timeout'));
    });

    try {
      if (confirmationRequired) {
        if (!consentGranted ||
            !RegExp(r'^(?:[0-9]{2}|[0-9]{3}|[0-9]{6})$')
                .hasMatch(confirmationCode)) {
          await _reject('number_matching_required');
          return;
        }
        _authorization = Completer<bool>();
        // Bind the server decision to this private request: operator-originated
        // signals cannot forge authorization through the shared signal channel.
        final random = Random.secure();
        _consentNonce = List.generate(32,
                (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'))
            .join();
        await send({
          'type': 'session_answer',
          'session_id': sessionId,
          'payload': {
            'session_id': sessionId,
            'stage': 'consent',
            'accepted': false,
            'consent_granted': true,
            'confirmation_code': confirmationCode,
            'consent_nonce': _consentNonce,
          },
        });
        final authorized = await Future.any<bool>([
          _authorization!.future,
          done.then((_) => false),
        ]).timeout(readyTimeout, onTimeout: () => false);
        if (!authorized || _closed) {
          await _reject('number_matching_failed');
          return;
        }
      }
      if (offerSdp.isEmpty ||
          utf8.encode(offerSdp).length > maxOfferSdpBytes ||
          iceServers.length > maxIceServers) {
        await _reject('invalid_offer');
        return;
      }
      final mediaLines = offerSdp.split(RegExp(r'\r?\n'));
      if (!mediaLines.any((line) => line.startsWith('m=video ')) ||
          ((accessMode == 'control' || accessMode == 'full_control') &&
              !mediaLines.any((line) => line.startsWith('m=application ')))) {
        await _reject('invalid_offer_media');
        return;
      }
      final answer = await peer.start(
        offerSdp: offerSdp,
        iceServers: iceServers,
        allowControl: accessMode == 'control' || accessMode == 'full_control',
        onCandidate: (candidate) => unawaited(_sendCandidate(candidate)),
        onFailure: () => unawaited(
          _ready ? close() : _reject('host_media_failed'),
        ),
      );
      if (_closed) return;
      if (answer.isEmpty || utf8.encode(answer).length > maxOfferSdpBytes) {
        throw const FormatException('Invalid Link answer SDP');
      }
      await send({
        'type': 'session_answer',
        'session_id': sessionId,
        'payload': {
          'session_id': sessionId,
          'accepted': true,
          'consent_granted': consentGranted,
          'sdp': answer,
        },
      });
      if (_closed) return;
      _ready = true;
      _readyTimer?.cancel();
      for (final candidate
          in List<Map<String, dynamic>>.of(_pendingCandidates)) {
        await peer.addRemoteCandidate(candidate);
      }
      _pendingCandidates.clear();
    } on LinkHostReadinessException catch (error) {
      await _reject(error.reason);
    } catch (_) {
      await _reject('host_worker_failed');
    }
  }

  Future<void> receive(Map<String, dynamic> frame) async {
    if (_closed) return;
    final frameSession = frame['session_id'];
    if (frameSession != sessionId) {
      await _reject('invalid_session_scope');
      return;
    }
    switch (frame['type']) {
      case 'signal':
        final raw = frame['signal'];
        if (raw is! Map) {
          await _reject('invalid_signal');
          return;
        }
        final signal = Map<String, dynamic>.from(raw);
        if (signal['type'] == 'consent_decision') {
          if (_authorization?.isCompleted == false &&
              _consentNonce != null &&
              signal['consent_nonce'] == _consentNonce) {
            _authorization!.complete(signal['authorized'] == true);
            _consentNonce = null;
          }
          return;
        }
        if (signal['type'] == 'ice_restart' ||
            signal['type'] == 'offer' ||
            signal['type'] == 'request_offer') {
          final sdp = signal['sdp'];
          if (_ready &&
              !_closed &&
              sdp is String &&
              sdp.isNotEmpty &&
              utf8.encode(sdp).length <= maxOfferSdpBytes) {
            try {
              final answer = await peer.renegotiateOffer(sdp);
              if (!_closed &&
                  answer.isNotEmpty &&
                  utf8.encode(answer).length <= maxOfferSdpBytes) {
                await send({
                  'type': 'session_answer',
                  'session_id': sessionId,
                  'payload': {
                    'session_id': sessionId,
                    'accepted': true,
                    'consent_granted': true,
                    'sdp': answer,
                  },
                });
              }
            } catch (e) {
              debugPrint('link_host: ice_restart renegotiation failed: $e');
            }
          }
          return;
        }
        final candidateValue = signal['candidate'];
        if (candidateValue is! Map) {
          debugPrint('link_host: ignoring non-candidate signal: ${signal['type']}');
          return;
        }
        final candidate = Map<String, dynamic>.from(candidateValue);
        if (!_ready) {
          if (_pendingCandidates.length >= maxPendingCandidates) {
            await _reject('candidate_queue_full');
            return;
          }
          _pendingCandidates.add(candidate);
          return;
        }
        try {
          await peer.addRemoteCandidate(candidate);
        } catch (e) {
          debugPrint('link_host: addRemoteCandidate failed (ignoring): $e');
        }
      case 'session_close':
      case 'session_revoke':
        await close();
        return;
      default:
        // Ignore unrelated agent protocol messages (heartbeat acknowledgments
        // are consumed by the WSS layer).
        return;
    }
  }

  Future<void> _sendCandidate(Map<String, dynamic> candidate) async {
    if (_closed) return;
    try {
      await send({
        'type': 'signal',
        'session_id': sessionId,
        'signal': {'type': 'candidate', 'candidate': candidate},
      });
    } catch (_) {
      await _reject('signaling_failed');
    }
  }

  Future<void> _reject(String reason) => _rejecting ??= _rejectOnce(reason);

  Future<void> _rejectOnce(String reason) async {
    if (_closed) return;
    // An accepted session has already been committed by the server. Notify
    // the server with session_terminate so the operator does not freeze.
    if (_ready) {
      if (reason != 'invalid_session_scope') {
        try {
          await send({
            'type': 'session_terminate',
            'session_id': sessionId,
            'payload': {
              'session_id': sessionId,
              'reason': reason,
            },
          });
        } catch (_) {}
      }
      await close();
      return;
    }
    try {
      await send({
        'type': 'session_answer',
        'session_id': sessionId,
        'payload': {
          'session_id': sessionId,
          'accepted': false,
          'reason': reason,
        },
      });
    } catch (_) {}
    await close();
  }

  Future<void> reject(String reason) => _reject(reason);

  Future<void> close() {
    final existing = _closing;
    if (existing != null) return existing;
    _closed = true;
    _readyTimer?.cancel();
    _pendingCandidates.clear();
    if (!_done.isCompleted) _done.complete();
    return _closing = peer.close();
  }
}

enum LinkHostWorkerPhase {
  starting,
  awaitingConsent,
  connecting,
  active,
  closing,
  closed
}

/// State shared by the visible local privacy indicator and the session worker.
class LinkHostWorkerState extends ChangeNotifier {
  final Completer<void> _disconnect = Completer<void>();
  Completer<bool>? _consent;
  void Function()? _disconnectHandler;

  LinkHostWorkerPhase phase = LinkHostWorkerPhase.starting;
  String accessMode = 'view';
  String? sessionId;
  String operatorName = '';
  String accessType = 'attended';
  String confirmationCode = '';
  int confirmationDigits = 2;
  bool recordingEnabled = false;
  bool recordingMandatory = false;
  String recordingReason = '';

  Future<void> get disconnectRequested => _disconnect.future;

  void showSession(String id, String mode, String operator,
      {String type = 'attended',
      int digits = 2,
      bool recording = false,
      bool mandatoryRecording = false,
      String policyReason = ''}) {
    confirmationCode = '';
    sessionId = id;
    accessMode = mode;
    final trimmedOperator = operator.trim();
    operatorName = String.fromCharCodes(trimmedOperator.runes.take(96));
    accessType = type;
    confirmationDigits = digits;
    recordingEnabled = recording;
    recordingMandatory = mandatoryRecording;
    recordingReason = policyReason;
    phase = type == 'attended'
        ? LinkHostWorkerPhase.awaitingConsent
        : LinkHostWorkerPhase.connecting;
    notifyListeners();
  }

  Future<bool> awaitConsent() {
    if (_disconnect.isCompleted || phase == LinkHostWorkerPhase.closed) {
      return Future<bool>.value(false);
    }
    _consent = Completer<bool>();
    phase = LinkHostWorkerPhase.awaitingConsent;
    notifyListeners();
    return _consent!.future.timeout(
      const Duration(seconds: 45),
      onTimeout: () => false,
    );
  }

  void approveConsent([String code = '']) {
    if (phase != LinkHostWorkerPhase.awaitingConsent ||
        _consent?.isCompleted != false) {
      return;
    }
    if (!RegExp(r'^(?:[0-9]{2}|[0-9]{3}|[0-9]{4}|[0-9]{6})$').hasMatch(code) ||
        code.length != confirmationDigits) {
      return;
    }
    confirmationCode = code;
    _consent!.complete(true);
    phase = LinkHostWorkerPhase.connecting;
    notifyListeners();
  }

  void denyConsent() {
    if (phase != LinkHostWorkerPhase.awaitingConsent ||
        _consent?.isCompleted != false) {
      return;
    }
    _consent!.complete(false);
    phase = LinkHostWorkerPhase.closing;
    notifyListeners();
  }

  void markActive() {
    if (phase == LinkHostWorkerPhase.connecting ||
        phase == LinkHostWorkerPhase.awaitingConsent) {
      phase = LinkHostWorkerPhase.active;
      notifyListeners();
    }
  }

  void setDisconnectHandler(void Function() handler) {
    _disconnectHandler = handler;
    if (_disconnect.isCompleted) handler();
  }

  void requestDisconnect() {
    if (_disconnect.isCompleted) return;
    if (_consent?.isCompleted == false) _consent!.complete(false);
    phase = LinkHostWorkerPhase.closing;
    _disconnect.complete();
    notifyListeners();
    _disconnectHandler?.call();
  }

  final List<SupportChatMessage> _chatMessages = [];
  List<SupportChatMessage> get chatMessages => List.unmodifiable(_chatMessages);
  int _unreadChatCount = 0;
  int get unreadChatCount => _unreadChatCount;
  void Function(Map<String, dynamic>)? _chatSender;

  void bindChatSender(void Function(Map<String, dynamic>) sender) {
    _chatSender = sender;
  }

  void receiveChatMessage(Map<String, dynamic> raw) {
    try {
      final msg = SupportChatMessage.fromJson(raw);
      final isDup = _chatMessages.any((m) {
        if (msg.clientId.isNotEmpty && m.clientId.isNotEmpty) {
          return m.clientId == msg.clientId;
        }
        if (msg.id.isNotEmpty && m.id.isNotEmpty) {
          return m.id == msg.id;
        }
        if (msg.clientId.isNotEmpty ||
            m.clientId.isNotEmpty ||
            msg.id.isNotEmpty ||
            m.id.isNotEmpty) {
          return false;
        }
        return m.sender == msg.sender &&
            m.text == msg.text &&
            m.timestamp.difference(msg.timestamp).abs().inSeconds < 5;
      });
      if (!isDup) {
        _chatMessages.add(msg);
        _chatMessages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
        if (msg.sender != 'user') {
          _unreadChatCount++;
        }
        notifyListeners();
      }
    } catch (e) {
      debugPrint('link_host: receiveChatMessage error: $e');
    }
  }

  void sendChatMessage(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    final now = DateTime.now();
    final ms = now.millisecondsSinceEpoch;
    final msg = SupportChatMessage(
      id: 'host_msg_$ms',
      sender: 'user',
      senderName: 'Пользователь',
      text: trimmed,
      timestamp: now,
      clientId: 'host-msg_$ms',
    );
    _chatMessages.add(msg);
    _chatMessages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    notifyListeners();
    _chatSender?.call(msg.toJson());
  }

  void clearUnreadChat() {
    if (_unreadChatCount > 0) {
      _unreadChatCount = 0;
      notifyListeners();
    }
  }

  void markClosed() {
    confirmationCode = '';
    if (_consent?.isCompleted == false) _consent!.complete(false);
    phase = LinkHostWorkerPhase.closed;
    notifyListeners();
  }
}

const _linkHostPipePrefix = r'\\.\pipe\LigamentLinkHost-';
final _linkHostPipeSuffix = RegExp(r'^[0-9a-f]{32}$');
final _linkHostUnixSocketPattern =
    RegExp(r'^/tmp/ligament-link-[A-Za-z0-9_-]{6,40}/worker\.sock$');
const _linkHostFrameLimit = 512 * 1024;

String? linkHostPipeFromArgs(List<String> args) {
  final flags = args.where((arg) => arg.startsWith('--link-host')).toList();
  if (flags.isEmpty) return null;
  const option = '--link-host=';
  if (flags.length != 1 || !flags.single.startsWith(option)) {
    throw const FormatException('Invalid Link worker option');
  }
  final pipe = flags.single.substring(option.length);
  if (!pipe.startsWith(_linkHostPipePrefix) ||
      !_linkHostPipeSuffix
          .hasMatch(pipe.substring(_linkHostPipePrefix.length))) {
    throw const FormatException('Invalid Link worker pipe');
  }
  return pipe;
}

String? linkHostUnixSocketFromArgs(List<String> args) {
  final flags = args.where((arg) => arg.startsWith('--link-host')).toList();
  if (flags.isEmpty) return null;
  const option = '--link-host=unix:';
  if (flags.length != 1 || !flags.single.startsWith(option)) {
    throw const FormatException('Invalid Link worker option');
  }
  final path = flags.single.substring(option.length);
  if (!_linkHostUnixSocketPattern.hasMatch(path)) {
    throw const FormatException('Invalid Link worker socket');
  }
  return path;
}

class _UnixLinkHostTransport {
  _UnixLinkHostTransport(this._socket) {
    _subscription = _socket.listen(
      _onData,
      onError: (Object error, StackTrace stack) => _fail(error, stack),
      onDone: () => _fail(StateError('Link worker socket closed')),
      cancelOnError: true,
    );
  }

  final Socket _socket;
  final List<int> _buffer = <int>[];
  final List<Uint8List> _frames = <Uint8List>[];
  final List<Completer<Uint8List>> _waiters = <Completer<Uint8List>>[];
  late final StreamSubscription<List<int>> _subscription;
  Object? _failure;
  bool _closed = false;

  static Future<_UnixLinkHostTransport> connect(String path) async =>
      _UnixLinkHostTransport(
        await Socket.connect(
          InternetAddress(path, type: InternetAddressType.unix),
          0,
          timeout: const Duration(seconds: 10),
        ),
      );

  Future<void> send(Map<String, dynamic> frame) async {
    if (_closed || _failure != null) {
      throw StateError('Link worker socket is closed');
    }
    final payload = Uint8List.fromList(utf8.encode(jsonEncode(frame)));
    if (payload.isEmpty || payload.length > _linkHostFrameLimit) {
      throw const FormatException('Link worker frame exceeds size limit');
    }
    final packet = Uint8List(payload.length + 4);
    ByteData.sublistView(packet).setUint32(0, payload.length, Endian.big);
    packet.setRange(4, packet.length, payload);
    _socket.add(packet);
    await _socket.flush();
  }

  Future<Uint8List> receive() {
    if (_frames.isNotEmpty) return Future<Uint8List>.value(_frames.removeAt(0));
    final failure = _failure;
    if (failure != null) return Future<Uint8List>.error(failure);
    final waiter = Completer<Uint8List>();
    _waiters.add(waiter);
    return waiter.future;
  }

  void _onData(List<int> chunk) {
    if (_closed) return;
    if (_buffer.length + chunk.length > (_linkHostFrameLimit + 4) * 8) {
      _fail(const FormatException('Link worker receive buffer exceeds limit'));
      return;
    }
    _buffer.addAll(chunk);
    while (_buffer.length >= 4) {
      final size = (_buffer[0] << 24) |
          (_buffer[1] << 16) |
          (_buffer[2] << 8) |
          _buffer[3];
      if (size == 0 || size > _linkHostFrameLimit) {
        _fail(const FormatException('Invalid Link worker frame size'));
        return;
      }
      if (_buffer.length < size + 4) return;
      final frame = Uint8List.fromList(_buffer.sublist(4, size + 4));
      _buffer.removeRange(0, size + 4);
      if (_waiters.isNotEmpty) {
        _waiters.removeAt(0).complete(frame);
      } else if (_frames.length < 8) {
        _frames.add(frame);
      } else {
        _fail(const FormatException('Too many queued Link worker frames'));
        return;
      }
    }
  }

  void _fail(Object error, [StackTrace? stack]) {
    if (_failure != null) return;
    _failure = error;
    unawaited(_socket.close());
    for (final waiter in _waiters) {
      if (!waiter.isCompleted) waiter.completeError(error, stack);
    }
    _waiters.clear();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _fail(StateError('Link worker transport closed'));
    await _subscription.cancel();
    await _socket.close();
  }
}

/// Entry point for an interactive, per-session worker. WSS stays in the agent;
/// the worker receives only its assigned offer and signaling frames.
Future<void> runLinkHostWorker(
  String endpoint, {
  required LinkHostWorkerState state,
}) async {
  final unixTransport = endpoint.startsWith('unix:')
      ? await _UnixLinkHostTransport.connect(endpoint.substring(5))
      : null;
  try {
    await _runConnectedLinkHostWorker(
      endpoint,
      state: state,
      unixTransport: unixTransport,
    );
  } finally {
    await unixTransport?.close();
  }
}

Future<void> _runConnectedLinkHostWorker(
  String endpoint, {
  required LinkHostWorkerState state,
  required _UnixLinkHostTransport? unixTransport,
}) async {
  String rawBootstrap;
  try {
    rawBootstrap = unixTransport == null
        ? await LinkHostSession._nativeChannel
                .invokeMethod<String>('bootstrap', endpoint)
                .timeout(const Duration(seconds: 10)) ??
            ''
        : utf8.decode(await unixTransport.receive().timeout(
              const Duration(seconds: 10),
            ));
  } catch (_) {
    await unixTransport?.close();
    rethrow;
  }
  if (rawBootstrap.length > _linkHostFrameLimit) {
    await unixTransport?.close();
    throw const FormatException('Invalid Link worker bootstrap frame');
  }
  final decoded = jsonDecode(rawBootstrap);
  if (decoded is! Map ||
      decoded['type'] != 'session_offer' ||
      decoded['payload'] is! Map) {
    await unixTransport?.close();
    throw const FormatException('Expected Link session offer bootstrap');
  }
  final offer = Map<String, dynamic>.from(decoded['payload'] as Map);
  final sessionId = offer['session_id'];
  final accessMode = offer['access_mode'];
  final operatorName = offer['operator_name'];
  final accessType = offer['access_type'];
  final confirmationRequired = offer['confirmation_required'];
  final confirmationDigits = offer['confirmation_digits'] ?? 6; // legacy server
  final sdp = offer['sdp'];
  final iceRaw = offer['ice_servers'];
  if (sessionId is! String ||
      accessMode is! String ||
      (accessType != 'attended' && accessType != 'unattended') ||
      confirmationRequired is! bool ||
      confirmationRequired != (accessType == 'attended') ||
      (accessType == 'attended' &&
          (confirmationDigits is! int ||
              !const [2, 3, 4, 6].contains(confirmationDigits))) ||
      sdp is! String ||
      (operatorName != null &&
          (operatorName is! String || operatorName.runes.length > 128)) ||
      (iceRaw != null && iceRaw is! List)) {
    await unixTransport?.close();
    throw const FormatException('Invalid Link session offer bootstrap');
  }
  final recordingConfig = LinkRecordingConfig.fromWire(offer['recording']);
  state.showSession(
    sessionId,
    accessMode,
    operatorName is String ? operatorName : '',
    type: accessType as String,
    digits: confirmationDigits is int ? confirmationDigits : 0,
    recording: recordingConfig.isActive,
    mandatoryRecording: recordingConfig.mandatory,
    policyReason: recordingConfig.policyReason,
  );
  final iceServers = <Map<String, dynamic>>[];
  if (iceRaw is List) {
    if (iceRaw.length > LinkHostSession.maxIceServers) {
      await unixTransport?.close();
      throw const FormatException('Too many Link ICE servers');
    }
    for (final entry in iceRaw) {
      if (entry is! Map) {
        await unixTransport?.close();
        throw const FormatException('Invalid Link ICE server');
      }
      iceServers.add(Map<String, dynamic>.from(entry));
    }
  }
  Future<void> outgoing = Future<void>.value();
  late final LinkHostSession session;
  final recorder = recordingConfig.isActive
      ? LinkHostRecorder(
          sessionId: sessionId,
          config: recordingConfig,
          onMandatoryViolation: (reason) => unawaited(session.reject(reason)),
        )
      : null;
  final peer = FlutterLinkHostPeer(
    onConnected: () {
      state.markActive();
      recorder?.start();
    },
    isRecorderReady: () =>
        recorder == null ||
        (!recorder.config.mandatory && !recorder.config.requireFirstFrame) ||
        recorder.firstFrameAcked,
    onControlInputObserved: recorder?.observeControlInput,
    onDesktopChanged: recorder?.notifyDesktopChanged,
    onChatMessageReceived: state.receiveChatMessage,
    onFrameCaptured: recorder == null
        ? null
        : (kind, bytes, monitorId) async {
            final frameInfo = await prepareRecordedFrame(bytes);
            if (frameInfo != null) {
              recorder.enqueueFrame(
                frameKind: kind,
                payload: frameInfo.payload,
                monitorId: monitorId,
                width: frameInfo.width,
                height: frameInfo.height,
                codec: frameInfo.codec,
              );
            }
          },
    policy: LinkSessionPolicy.fromWire(offer['dlp']),
  );
  state.bindChatSender(peer.sendChatMessage);
  session = LinkHostSession(
    sessionId: sessionId,
    accessMode: accessMode,
    peer: peer,
    send: (frame) {
      final next = outgoing.then((_) async {
        if (unixTransport != null) {
          await unixTransport.send(frame);
        } else {
          final accepted = await LinkHostSession._nativeChannel
              .invokeMethod<bool>('send', jsonEncode(frame));
          if (accepted != true) {
            throw StateError('Link worker pipe rejected frame');
          }
        }
      });
      outgoing = next;
      return next;
    },
  );
  state.setDisconnectHandler(
    () => unawaited(session.reject('host_local_disconnect')),
  );
  var polling = false;
  final timer = Timer.periodic(const Duration(milliseconds: 10), (_) async {
    if (polling || session.isClosed) return;
    polling = true;
    try {
      final frame = unixTransport != null
          ? utf8.decode(await unixTransport.receive())
          : await LinkHostSession._nativeChannel
                  .invokeMethod<String?>('receive') ??
              '';
      if (frame.isNotEmpty) {
        try {
          final message = jsonDecode(frame);
          if (message is Map) {
            await session.receive(Map<String, dynamic>.from(message));
          }
        } on FormatException catch (e) {
          debugPrint('link host IPC frame format error: $e');
        } catch (e) {
          debugPrint('link host IPC message decode error: $e');
        }
      }
    } catch (e) {
      debugPrint('link host IPC transport error: $e');
      await session.close();
    } finally {
      polling = false;
    }
  });
  try {
    final consentGranted = accessType == 'attended'
        ? await Future.any<bool>([
            state.awaitConsent(),
            session.done.then((_) => false),
          ])
        : false;
    if (session.isClosed ||
        state.phase == LinkHostWorkerPhase.closing ||
        (accessType == 'attended' && !consentGranted)) {
      if (!session.isClosed) await session.reject('host_consent_denied');
    } else {
      final enteredCode = state.confirmationCode;
      state.confirmationCode = '';
      await session.start(
        offerSdp: sdp,
        iceServers: iceServers,
        consentGranted: consentGranted,
        confirmationRequired: confirmationRequired,
        confirmationCode: enteredCode,
      );
    }
    await Future.any<void>([session.done, state.disconnectRequested]);
    if (state.phase == LinkHostWorkerPhase.closing) {
      try {
        await session.send({
          'type': 'session_terminate',
          'session_id': sessionId,
          'payload': {
            'session_id': sessionId,
            'reason': 'host_local_disconnect',
          },
        });
      } catch (_) {}
    }
  } finally {
    timer.cancel();
    await recorder?.stop(reason: 'session_ended');
    await session.close();
    if (unixTransport != null) {
      await unixTransport.close();
    } else {
      try {
        await LinkHostSession._nativeChannel.invokeMethod<void>('close');
      } catch (_) {}
    }
    state.markClosed();
  }
}

class _LinkActiveFileDownload {
  _LinkActiveFileDownload({
    required this.id,
    required this.filename,
    required this.totalSize,
    required this.totalChunks,
    this.expectedChecksum,
  });

  final String id;
  final String filename;
  final int totalSize;
  final int totalChunks;
  final String? expectedChecksum;
  final Map<int, List<int>> chunks = {};
  int receivedBytes = 0;
  Timer? stallTimer;
}

/// Flutter WebRTC peer implementation used by the interactive Link worker.
class FlutterLinkHostPeer implements LinkHostPeer {
  FlutterLinkHostPeer({
    this.onConnected,
    this.onControlInputObserved,
    this.onDesktopChanged,
    this.onChatMessageReceived,
    this.onFrameCaptured,
    this.isRecorderReady,
    this.policy = const LinkSessionPolicy(),
  });

  static const Duration connectionGracePeriod = Duration(seconds: 60);
  static const int _maxFileTransferBytes = 50 * 1024 * 1024;
  static const int _maxConcurrentDownloads = 4;
  static const Duration _downloadStallTimeout = Duration(seconds: 30);

  final VoidCallback? onConnected;
  final void Function(Map<String, dynamic> input)? onControlInputObserved;
  final void Function()? onDesktopChanged;
  final void Function(Map<String, dynamic> message)? onChatMessageReceived;
  final void Function(String frameKind, Uint8List bytes, String monitorId)?
      onFrameCaptured;
  final bool Function()? isRecorderReady;
  final LinkSessionPolicy policy;

  RTCPeerConnection? _peer;
  MediaStream? _stream;
  MediaStream? _audioStream;
  RTCRtpSender? _videoSender;
  RTCRtpSender? _audioSender;
  RTCDataChannel? _control;
  ScreenRect? _screenRect;
  String? _selectedScreenId;
  Timer? _connectionGraceTimer;
  Timer? _recorderFrameTimer;
  Timer? _activitySnapshotTimer;
  Timer? _desktopSwitchTimer;
  Timer? _desktopSwitchDebounceTimer;
  DateTime? _lastFrameCaptureAt;
  bool _capturingFrame = false;
  bool _switchingScreen = false;
  bool _pendingScreenSwitch = false;
  String? _pendingScreenId;
  final Map<String, _LinkActiveFileDownload> _activeDownloads = {};
  final List<Map<String, dynamic>> _pendingChatMessages = [];
  bool _allowControl = false;
  bool _closed = false;

  Future<void> _captureRecorderSnapshot(String frameKind) async {
    final cb = onFrameCaptured;
    if (cb == null || _closed || _capturingFrame || _switchingScreen) return;
    _capturingFrame = true;
    try {
      Uint8List? bytes;
      String currentMonitorId = _selectedScreenId ?? '0';

      // 1. Если ID монитора неизвестен или '0', инициализируем sources в C++ плагине
      if (_selectedScreenId == null || _selectedScreenId == '0') {
        try {
          final sources = await desktopCapturer
              .getSources(types: [SourceType.Screen])
              .timeout(const Duration(seconds: 3));
          if (sources.isNotEmpty) {
            _selectedScreenId = sources.first.id;
            currentMonitorId = sources.first.id;
          }
        } catch (_) {}
      }

      // 2. Штатный запрос миниатюры через WebRTC
      try {
        final raw = await WebRTC.invokeMethod(
          'getDesktopSourceThumbnail',
          <String, dynamic>{
            'sourceId': currentMonitorId,
            'thumbnailSize': {'width': 1280, 'height': 720},
          },
        ).timeout(const Duration(seconds: 2));
        if (raw is Uint8List && raw.isNotEmpty) {
          bytes = raw;
        }
      } catch (_) {}

      // 3. Если sources_ в WebRTC оказались пустыми или устарели, обновляем и повторяем
      if (bytes == null && !_closed) {
        try {
          final sources = await desktopCapturer
              .getSources(types: [SourceType.Screen])
              .timeout(const Duration(seconds: 3));
          if (sources.isNotEmpty) {
            currentMonitorId = sources.first.id;
            _selectedScreenId = currentMonitorId;
            final retryRaw = await WebRTC.invokeMethod(
              'getDesktopSourceThumbnail',
              <String, dynamic>{
                'sourceId': currentMonitorId,
                'thumbnailSize': {'width': 1280, 'height': 720},
              },
            ).timeout(const Duration(seconds: 2));
            if (retryRaw is Uint8List && retryRaw.isNotEmpty) {
              bytes = retryRaw;
            }
          }
        } catch (_) {}
      }

      // 4. Резервный канал на Windows: прямой захват активного экрана через Win32 GDI
      if (bytes == null && !_closed && !kIsWeb && Platform.isWindows) {
        try {
          bytes = InputInjector.instance.captureDesktopBmp(maxWidth: 1280, maxHeight: 720);
        } catch (_) {}
      }

      // NOTE: Never fall back to `tracks.first.captureFrame()` on desktop:
      // flutter_webrtc's C++ FlutterFrameCapturer::CaptureFrame executes a
      // synchronous `while(!catch_frame_){}` busy-wait on the Win32 UI thread,
      // which deadlocks at 100% CPU during Winlogon -> Default transitions.
      if (bytes != null && bytes.isNotEmpty && !_closed) {
        _lastFrameCaptureAt = DateTime.now();
        cb(frameKind, bytes, currentMonitorId);
      }
    } catch (_) {
    } finally {
      _capturingFrame = false;
    }
  }

  Future<void> _sendScreenList() async {
    final control = _control;
    if (control == null || _closed) return;
    try {
      final sources = await desktopCapturer
          .getSources(types: [SourceType.Screen])
          .timeout(const Duration(seconds: 10));
      final screens = <Map<String, dynamic>>[];
      for (final src in sources) {
        final rect = InputInjector.instance.getMonitorRectForSource(src.id);
        screens.add({
          'id': src.id,
          'name': src.name.isNotEmpty ? src.name : 'Monitor ${src.id}',
          if (rect != null) 'rect': rect.toJson(),
        });
      }
      final payload = {
        'type': 'screen_list',
        'screens': screens,
        if (_selectedScreenId != null) 'selected_id': _selectedScreenId,
        if (!kIsWeb &&
            (Platform.isWindows || Platform.isLinux || Platform.isMacOS))
          'virtual_desktop':
              InputInjector.instance.getVirtualDesktopRect().toJson(),
      };
      control.send(RTCDataChannelMessage(jsonEncode(payload)));
    } catch (e) {
      debugPrint('link_host_session: _sendScreenList failed: $e');
    }
  }

  Future<MediaStream> _openDisplayStream(String sourceId,
      {bool withAudio = true}) async {
    final videoConstraints = <String, dynamic>{
      'deviceId': {'exact': sourceId},
      'cursor': 'always',
    };
    final wantLoopbackAudio =
        withAudio && !kIsWeb && (Platform.isWindows || Platform.isLinux);
    MediaStream? stream;
    if (wantLoopbackAudio) {
      try {
        stream = await navigator.mediaDevices.getDisplayMedia(<String, dynamic>{
          'audio': true,
          'video': videoConstraints,
        }).timeout(const Duration(seconds: 4));
        final audioCount = stream.getAudioTracks().length;
        debugPrint(
            'link_host_session: loopback getDisplayMedia returned audioTracks=$audioCount');
      } catch (e) {
        debugPrint(
            'link_host_session: loopback audio unavailable, falling back to video-only: $e');
      }
    }
    stream ??= await navigator.mediaDevices.getDisplayMedia(<String, dynamic>{
      'audio': false,
      'video': videoConstraints,
    }).timeout(const Duration(seconds: 5));
    return stream;
  }

  Future<void> switchScreen(String screenId) async {
    if (kIsWeb || _peer == null || _closed) return;
    if (_switchingScreen) {
      _pendingScreenSwitch = true;
      _pendingScreenId = screenId;
      return;
    }
    _switchingScreen = true;
    try {
      var targetScreenId = screenId;
      MediaStream? newStream;
      final needAudio =
          _audioStream == null || _audioStream!.getAudioTracks().isEmpty;

      const backoffs = [100, 250, 500, 1000];
      final startTime = DateTime.now();
      var attempt = 0;

      while (DateTime.now().difference(startTime) < const Duration(seconds: 10)) {
        if (_closed || _peer == null) return;
        try {
          final sources = await desktopCapturer
              .getSources(types: [SourceType.Screen])
              .timeout(const Duration(seconds: 3));
          if (sources.isNotEmpty &&
              !sources.any((s) => s.id == targetScreenId)) {
            targetScreenId = sources.first.id;
          }
          newStream =
              await _openDisplayStream(targetScreenId, withAudio: needAudio);
          if (newStream.getVideoTracks().isNotEmpty) {
            break;
          }
        } catch (e) {
          debugPrint(
              'link_host_session: _openDisplayStream attempt $attempt failed: $e');
        }
        final delayMs = attempt < backoffs.length ? backoffs[attempt] : 1000;
        attempt++;
        if (DateTime.now().difference(startTime) + Duration(milliseconds: delayMs) >=
            const Duration(seconds: 10)) {
          break;
        }
        await Future<void>.delayed(Duration(milliseconds: delayMs));
      }

      if (newStream == null) {
        debugPrint(
            'link_host_session: failed to acquire new stream during switch within 10s backoff limit');
        return;
      }

      if (_closed || _peer == null) {
        for (final t in newStream.getTracks()) {
          t.stop();
        }
        await newStream.dispose();
        return;
      }

      final newVideoTracks = newStream.getVideoTracks();
      if (newVideoTracks.isNotEmpty) {
        if (_videoSender != null) {
          await _videoSender!.replaceTrack(newVideoTracks.first);
        } else {
          final senders = await _peer!.getSenders();
          for (final sender in senders) {
            if (sender.track?.kind == 'video') {
              _videoSender = sender;
              await sender.replaceTrack(newVideoTracks.first);
              break;
            }
          }
        }
      }

      final newAudioTracks = newStream.getAudioTracks();
      if (newAudioTracks.isNotEmpty) {
        _audioStream = newStream;
        if (_audioSender != null) {
          await _audioSender!.replaceTrack(newAudioTracks.first);
        } else {
          final senders = await _peer!.getSenders();
          for (final sender in senders) {
            if (sender.track?.kind == 'audio') {
              _audioSender = sender;
              await sender.replaceTrack(newAudioTracks.first);
              break;
            }
          }
          if (_audioSender == null && _peer != null) {
            _audioSender =
                await _peer!.addTrack(newAudioTracks.first, newStream);
          }
        }
      }

      final oldStream = _stream;
      _stream = newStream;
      _selectedScreenId = targetScreenId;

      if (oldStream != null) {
        // Останавливаем только видеотреки старого потока, сохраняя системное аудио ПК
        for (final t in oldStream.getVideoTracks()) {
          try {
            await t.stop();
          } catch (_) {}
        }
        if (oldStream != _audioStream) {
          try {
            await oldStream.dispose();
          } catch (_) {}
        }
      }

      _screenRect =
          InputInjector.instance.getMonitorRectForSource(targetScreenId);
      InputInjector.instance.setActiveMonitorRect(_screenRect);
      await _sendScreenList();
    } catch (e) {
      debugPrint('link_host_session: switchScreen failed: $e');
    } finally {
      _switchingScreen = false;
      if (_pendingScreenSwitch && !_closed) {
        _pendingScreenSwitch = false;
        final nextId = _pendingScreenId ?? _selectedScreenId ?? '0';
        _pendingScreenId = null;
        unawaited(switchScreen(nextId));
      }
    }
  }

  @override
  Future<String> start({
    required String offerSdp,
    required List<Map<String, dynamic>> iceServers,
    required bool allowControl,
    required void Function(Map<String, dynamic>) onCandidate,
    required void Function() onFailure,
  }) async {
    _allowControl = allowControl;
    await ensureLinkHostInputReady(allowControl: allowControl);
    final peer = await createPeerConnection({
      'iceServers': iceServers,
      'sdpSemantics': 'unified-plan',
    });
    _peer = peer;
    peer.onIceCandidate = (candidate) {
      if (_closed ||
          candidate.candidate == null ||
          candidate.candidate!.isEmpty) {
        return;
      }
      onCandidate(Map<String, dynamic>.from(candidate.toMap()));
    };
    peer.onDataChannel = (channel) {
      if (channel.label != 'link-control-v1' && channel.label != 'control') {
        unawaited(channel.close());
        return;
      }
      final prevControl = _control;
      if (prevControl != null && !identical(prevControl, channel)) {
        prevControl.onMessage = null;
        unawaited(prevControl.close());
      }
      _control = channel;
      channel.onDataChannelState = (state) {
        if (state == RTCDataChannelState.RTCDataChannelOpen) {
          _sendScreenList();
          _flushPendingChatMessages();
        } else if (state == RTCDataChannelState.RTCDataChannelClosed) {
          if (identical(_control, channel)) {
            _control = null;
          }
          InputInjector.instance.releaseAllPressed();
        }
      };
      channel.onMessage = (message) {
        if (_closed || message.isBinary) return;
        try {
          final decoded = jsonDecode(message.text);
          if (decoded is Map) {
            final control = Map<String, dynamic>.from(decoded);
            if (control['type'] == 'ping') {
              try {
                channel.send(RTCDataChannelMessage(jsonEncode({
                  'type': 'pong',
                  'timestamp': control['timestamp'] ??
                      DateTime.now().millisecondsSinceEpoch,
                })));
              } catch (_) {}
              return;
            }
            if (_isValidInput(control)) _executeInput(control);
          }
        } on FormatException {
          // Malformed DTLS payloads are ignored; they never reach the injector.
        }
      };
    };
    peer.onConnectionState = (state) {
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        _connectionGraceTimer?.cancel();
        _connectionGraceTimer = null;
        InputInjector.instance.setKeepSessionAwake(true);
        if (!kIsWeb && Platform.isWindows) {
          _desktopSwitchTimer?.cancel();
          _desktopSwitchTimer = Timer.periodic(
            const Duration(milliseconds: 200),
            (_) {
              if (!_closed && InputInjector.instance.consumeDesktopChanged()) {
                onDesktopChanged?.call();
                final screenId = _selectedScreenId ?? '0';
                _desktopSwitchDebounceTimer?.cancel();
                // Дебаунс 300мс даёт Windows завершить смену десктопа (Default <-> Winlogon) перед запросом DXGI
                _desktopSwitchDebounceTimer = Timer(
                  const Duration(milliseconds: 300),
                  () {
                    if (_closed) return;
                    unawaited(switchScreen(_selectedScreenId ?? screenId));
                  },
                );
              }
            },
          );
        }
        onConnected?.call();
        if (onFrameCaptured != null) {
          unawaited(_captureRecorderSnapshot('keyframe'));
          _recorderFrameTimer?.cancel();
          _recorderFrameTimer = Timer.periodic(
            const Duration(seconds: 4),
            (_) {
              unawaited(_captureRecorderSnapshot('periodic'));
            },
          );
        }
      } else if (state ==
              RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        _connectionGraceTimer ??= Timer(connectionGracePeriod, () {
          _connectionGraceTimer = null;
          if (!_closed) {
            onFailure();
          }
        });
      } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        _connectionGraceTimer?.cancel();
        _connectionGraceTimer = null;
        onFailure();
      }
    };

    await peer.setRemoteDescription(RTCSessionDescription(offerSdp, 'offer'));
    final capture = await _captureScreen();
    if (_closed) {
      capture.getTracks().forEach((track) => track.stop());
      await capture.dispose();
      throw StateError('Link host peer closed during capture');
    }
    _stream = capture;
    if (capture.getAudioTracks().isNotEmpty) {
      _audioStream = capture;
    }
    for (final track in capture.getVideoTracks()) {
      _videoSender = await peer.addTrack(track, capture);
    }
    for (final track in capture.getAudioTracks()) {
      _audioSender = await peer.addTrack(track, capture);
    }
    try {
      final transceivers = await peer.getTransceivers();
      for (final t in transceivers) {
        await t.setDirection(TransceiverDirection.SendOnly);
      }
    } catch (e) {
      debugPrint('link_host_session: setDirection on transceivers: $e');
    }
    final answer = await peer.createAnswer();
    await peer.setLocalDescription(answer);
    debugPrint(
        'link_host_session: answer created, videoSender=${_videoSender != null}, audioSender=${_audioSender != null}, audioTracks=${capture.getAudioTracks().length}');
    return answer.sdp ?? '';
  }

  @override
  Future<String> renegotiateOffer(String offerSdp) async {
    final peer = _peer;
    if (_closed || peer == null) {
      throw StateError('Link host peer is not active');
    }
    _connectionGraceTimer?.cancel();
    _connectionGraceTimer = null;
    await peer.setRemoteDescription(RTCSessionDescription(offerSdp, 'offer'));
    try {
      final transceivers = await peer.getTransceivers();
      for (final t in transceivers) {
        await t.setDirection(TransceiverDirection.SendOnly);
      }
    } catch (e) {
      debugPrint('link_host_session: renegotiate setDirection on transceivers: $e');
    }
    final answer = await peer.createAnswer();
    await peer.setLocalDescription(answer);
    return answer.sdp ?? '';
  }

  void sendChatMessage(Map<String, dynamic> message) {
    final sent = _sendControlJson(message);
    if (!sent && _pendingChatMessages.length < 256) {
      _pendingChatMessages.add(Map<String, dynamic>.from(message));
    }
  }

  void _flushPendingChatMessages() {
    if (_pendingChatMessages.isEmpty) return;
    final toSend = List<Map<String, dynamic>>.from(_pendingChatMessages);
    _pendingChatMessages.clear();
    for (final msg in toSend) {
      final sent = _sendControlJson(msg);
      if (!sent && _pendingChatMessages.length < 256) {
        _pendingChatMessages.add(msg);
      }
    }
  }

  static bool isValidInput(Map<String, dynamic> input) => _isValidInput(input);

  static bool _isValidInput(Map<String, dynamic> input) {
    final type = input['type'];
    if (type == 'ping' || type == 'pong') {
      return true;
    }
    if (type == 'chat_message') {
      final text = input['text'];
      return text is String && text.trim().isNotEmpty && text.length <= 4096;
    }
    if (type == 'chat_sync') {
      return input['messages'] is List;
    }
    if (type == 'chat_ack') {
      return true;
    }
    if (type == 'mouse_move' || type == 'mouse_down' || type == 'mouse_up') {
      final x = input['x'];
      final y = input['y'];
      if (x is! num ||
          y is! num ||
          !x.toDouble().isFinite ||
          !y.toDouble().isFinite ||
          x < 0 ||
          x > 1 ||
          y < 0 ||
          y > 1) {
        return false;
      }
      if (type != 'mouse_move') {
        final button = input['button'];
        if (button is! int || button < 0 || button > 2) return false;
      }
      return true;
    }
    if (type == 'wheel') {
      final delta = input['deltaY'];
      return delta is num && delta.toDouble().isFinite && delta.abs() <= 1200;
    }
    if (type == 'key_down' || type == 'key_up') {
      return LinkKeyMessage.tryParse(input) != null;
    }
    if (type == 'hotkey') {
      final action = input['action'];
      return action is String && action.isNotEmpty;
    }
    if (type == 'screen_list') {
      return true;
    }
    if (type == 'switch_screen') {
      final sId = input['screen_id'];
      return sId != null && sId.toString().isNotEmpty;
    }
    if (type == 'clipboard_set') {
      final text = input['text'];
      return text is String && text.length <= 65536;
    }
    if (type == 'clipboard_get') {
      return true;
    }
    if (type == 'block_input') {
      return input['blocked'] is bool;
    }
    if (type == 'text_input') {
      final text = input['text'];
      return text is String && text.isNotEmpty && text.length <= 4096;
    }
    if (type == 'video_quality') {
      final quality = input['quality'];
      final bitrate = input['bitrate'];
      return (quality is String &&
              const {'best', 'balanced', 'low', 'high', 'medium'}
                  .contains(quality)) ||
          (bitrate is int && bitrate >= 100000 && bitrate <= 20000000);
    }
    if (type == 'reboot') {
      return true;
    }
    if (type == 'file_start') {
      final id = input['transfer_id'] ?? input['id'];
      final filename = input['filename'];
      final size = input['size'];
      final chunks = input['total_chunks'];
      return id is String &&
          id.isNotEmpty &&
          filename is String &&
          filename.isNotEmpty &&
          (size == null ||
              (size is int && size >= 0 && size <= _maxFileTransferBytes)) &&
          (chunks == null || (chunks is int && chunks > 0 && chunks <= 8192));
    }
    if (type == 'file_chunk') {
      final id = input['transfer_id'] ?? input['id'];
      final idx = input['chunk_index'];
      final data = input['data'];
      return id is String &&
          id.isNotEmpty &&
          idx is int &&
          idx >= 0 &&
          data is String &&
          data.isNotEmpty;
    }
    if (type == 'file_end') {
      final id = input['transfer_id'] ?? input['id'];
      return id is String && id.isNotEmpty;
    }
    return false;
  }

  void _executeInput(Map<String, dynamic> input) {
    if (_closed || !policy.allows(input, allowControl: _allowControl)) return;
    final type = input['type'];
    if (type != 'chat_message' && type != 'chat_sync' && type != 'chat_ack') {
      if (isRecorderReady != null && !isRecorderReady!()) {
        return; // Gated until durable first frame is acked (ULR-03)
      }
    }
    onControlInputObserved?.call(input);
    if (type == 'chat_message') {
      _sendControlJson({
        'type': 'chat_ack',
        'id': input['id'],
        'client_id': input['client_id'],
      });
      onChatMessageReceived?.call(input);
      return;
    }
    if (type == 'chat_sync') {
      final list = input['messages'];
      if (list is List) {
        for (final item in list) {
          if (item is Map) {
            onChatMessageReceived?.call(Map<String, dynamic>.from(item));
          }
        }
      }
      return;
    }
    if (type == 'chat_ack') {
      return;
    }
    if (onFrameCaptured != null &&
        (type == 'mouse_down' || type == 'key_down' || type == 'hotkey')) {
      final now = DateTime.now();
      if (_activitySnapshotTimer == null &&
          (_lastFrameCaptureAt == null ||
              now.difference(_lastFrameCaptureAt!) >=
                  const Duration(milliseconds: 1500))) {
        _activitySnapshotTimer = Timer(
          const Duration(milliseconds: 500),
          () {
            _activitySnapshotTimer = null;
            if (!_closed) {
              unawaited(_captureRecorderSnapshot('activity'));
            }
          },
        );
      }
    }
    final injector = InputInjector.instance;
    try {
      if (type == 'mouse_move' || type == 'mouse_down' || type == 'mouse_up') {
        final x = (input['x'] as num).toDouble();
        final y = (input['y'] as num).toDouble();
        if (type == 'mouse_move') {
          injector.moveMouse(x, y, screenRect: _screenRect);
        } else {
          injector.mouseAction(
            action: type == 'mouse_down' ? 'down' : 'up',
            button: input['button'] as int,
            normX: x,
            normY: y,
            screenRect: _screenRect,
          );
        }
      } else if (type == 'wheel') {
        injector.mouseWheel((input['deltaY'] as num).toDouble());
      } else if (type == 'key_down' || type == 'key_up') {
        LinkKeyMessage.tryParse(input)?.inject(injector.keyAction);
      } else if (type == 'hotkey') {
        injector.triggerHotkey(input['action'] as String);
      } else if (type == 'text_input') {
        unawaited(_handleTextInput(input['text']?.toString() ?? ''));
      } else if (type == 'screen_list') {
        _sendScreenList();
      } else if (type == 'switch_screen') {
        final screenId = input['screen_id']?.toString();
        if (screenId != null) {
          switchScreen(screenId);
        }
      } else if (type == 'video_quality') {
        _handleVideoQuality(input);
      } else if (type == 'reboot') {
        _handleRemoteReboot();
      } else if (type == 'file_start') {
        _handleFileStart(input);
      } else if (type == 'file_chunk') {
        _handleFileChunk(input);
      } else if (type == 'file_end') {
        unawaited(_handleFileEnd(input));
      } else if (type == 'clipboard_set') {
        final text = input['text']?.toString() ?? '';
        if (text.length <= 65536) {
          Clipboard.setData(ClipboardData(text: text));
        }
      } else if (type == 'clipboard_get') {
        Clipboard.getData(Clipboard.kTextPlain).then((clip) {
          if (_closed || !policy.allowClipboardOut || !_allowControl) return;
          final text = clip?.text ?? '';
          if (text.length > LinkSessionPolicy.maxClipboardLength) return;
          _control?.send(RTCDataChannelMessage(jsonEncode({
            'type': 'clipboard_data',
            'text': text,
          })));
        });
      } else if (type == 'block_input') {
        final blocked = input['blocked'] == true;
        injector.setInputBlocked(blocked);
        _sendControlJson({
          'type': 'block_input_ack',
          'blocked': blocked,
        });
      }
    } catch (_) {
      if (type == 'block_input') {
        _sendControlJson({
          'type': 'block_input_ack',
          'blocked': false,
          'error': 'input_rejected',
        });
        return;
      }
      _sendControlJson({
        'type': 'input_error',
      });
    }
  }

  bool _sendControlJson(Map<String, dynamic> payload) {
    final control = _control;
    if (_closed ||
        control == null ||
        control.state != RTCDataChannelState.RTCDataChannelOpen) {
      return false;
    }
    try {
      control.send(RTCDataChannelMessage(jsonEncode(payload)));
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _handleTextInput(String text) async {
    if (text.isEmpty || text.length > 4096 || _closed) return;
    final injector = InputInjector.instance;
    if (!kIsWeb && Platform.isWindows) {
      for (int i = 0; i < text.length; i++) {
        injector.keyAction(action: 'down', key: text[i], char: text[i]);
        injector.keyAction(action: 'up', key: text[i], char: text[i]);
      }
    } else if (!kIsWeb && Platform.isMacOS) {
      await Clipboard.setData(ClipboardData(text: text));
      await injector.triggerHotkey('cmd_v');
    } else if (!kIsWeb && Platform.isLinux) {
      await Process.run('xdotool', ['type', '--', text]);
    } else {
      await Clipboard.setData(ClipboardData(text: text));
      await injector.triggerHotkey('ctrl_v');
    }
  }

  void _handleVideoQuality(Map<String, dynamic> input) {
    final peer = _peer;
    if (peer == null || _closed) return;
    final quality = input['quality']?.toString() ?? 'balanced';
    final int bitrate;
    switch (quality) {
      case 'best':
      case 'high':
        bitrate = 4000000;
        break;
      case 'low':
        bitrate = 800000;
        break;
      case 'balanced':
      case 'medium':
      default:
        bitrate = (input['bitrate'] as num?)?.toInt() ?? 2500000;
        break;
    }
    unawaited(() async {
      try {
        final senders = await peer.getSenders();
        for (final sender in senders) {
          if (sender.track?.kind == 'video') {
            final params = sender.parameters;
            final encodings = params.encodings;
            if (encodings != null && encodings.isNotEmpty) {
              for (final enc in encodings) {
                enc.maxBitrate = bitrate;
              }
              await sender.setParameters(params);
            }
          }
        }
      } catch (e) {
        debugPrint('link_host: set video_quality failed: $e');
      }
    }());
  }

  void _handleRemoteReboot() {
    try {
      if (!kIsWeb && Platform.isWindows) {
        Process.run('shutdown', [
          '/r',
          '/t',
          '5',
          '/f',
          '/c',
          'Reboot requested by remote operator',
        ]);
      } else if (!kIsWeb && Platform.isLinux) {
        Process.run('systemctl', ['reboot']).catchError((_) {
          return Process.run('shutdown', ['-r', 'now']);
        });
      } else if (!kIsWeb && Platform.isMacOS) {
        Process.run('shutdown', ['-r', 'now']);
      }
    } catch (e) {
      debugPrint('link_host: reboot failed: $e');
    }
  }

  void _handleFileStart(Map<String, dynamic> input) {
    final transferId =
        input['transfer_id']?.toString() ?? input['id']?.toString() ?? '';
    if (transferId.isEmpty) return;
    final filename = input['filename']?.toString() ??
        'file_${DateTime.now().millisecondsSinceEpoch}';
    final size = (input['size'] as num?)?.toInt() ?? 0;
    final totalChunks = (input['total_chunks'] as num?)?.toInt() ?? 1;
    if (size < 0 ||
        size > _maxFileTransferBytes ||
        totalChunks <= 0 ||
        _activeDownloads.length >= _maxConcurrentDownloads) {
      _sendControlJson({
        'type': 'file_ack',
        'transfer_id': transferId,
        'ok': false,
      });
      return;
    }
    _activeDownloads.remove(transferId)?.stallTimer?.cancel();
    final dl = _LinkActiveFileDownload(
      id: transferId,
      filename: filename,
      totalSize: size,
      totalChunks: totalChunks,
      expectedChecksum: input['checksum']?.toString(),
    );
    dl.stallTimer = Timer(_downloadStallTimeout, () {
      _activeDownloads.remove(transferId);
      _sendControlJson({
        'type': 'file_ack',
        'transfer_id': transferId,
        'ok': false,
      });
    });
    _activeDownloads[transferId] = dl;
  }

  void _handleFileChunk(Map<String, dynamic> input) {
    final transferId =
        input['transfer_id']?.toString() ?? input['id']?.toString() ?? '';
    final chunkIndex = (input['chunk_index'] as num?)?.toInt() ?? -1;
    final base64Data = input['data']?.toString() ?? '';
    final dl = _activeDownloads[transferId];
    if (dl == null || base64Data.isEmpty) return;
    try {
      final bytes = base64Decode(base64Data);
      if (chunkIndex < 0 || chunkIndex >= dl.totalChunks) return;
      if (!dl.chunks.containsKey(chunkIndex)) {
        dl.receivedBytes += bytes.length;
      }
      if (dl.receivedBytes > _maxFileTransferBytes) {
        _activeDownloads.remove(transferId)?.stallTimer?.cancel();
        _sendControlJson({
          'type': 'file_ack',
          'transfer_id': transferId,
          'ok': false,
        });
        return;
      }
      dl.chunks[chunkIndex] = bytes;
      dl.stallTimer?.cancel();
      dl.stallTimer = Timer(_downloadStallTimeout, () {
        _activeDownloads.remove(transferId);
        _sendControlJson({
          'type': 'file_ack',
          'transfer_id': transferId,
          'ok': false,
        });
      });
    } catch (_) {
      _activeDownloads.remove(transferId)?.stallTimer?.cancel();
      _sendControlJson({
        'type': 'file_ack',
        'transfer_id': transferId,
        'ok': false,
      });
    }
  }

  Future<void> _handleFileEnd(Map<String, dynamic> input) async {
    final transferId =
        input['transfer_id']?.toString() ?? input['id']?.toString() ?? '';
    final dl = _activeDownloads.remove(transferId);
    dl?.stallTimer?.cancel();
    if (dl == null) return;
    final endChecksum = input['checksum']?.toString();
    final checksum = (endChecksum != null && endChecksum.isNotEmpty)
        ? endChecksum
        : dl.expectedChecksum;
    final result = assembleFileChunks(
      dl.chunks,
      dl.totalChunks,
      expectedSize: dl.totalSize > 0 ? dl.totalSize : null,
      expectedChecksum: checksum,
    );
    if (!result.isOk || result.bytes == null) {
      _sendControlJson({
        'type': 'file_ack',
        'transfer_id': transferId,
        'ok': false,
      });
      _sendControlJson({
        'type': 'file_reject',
        'transfer_id': transferId,
        'filename': dl.filename,
        'reason': result.error ?? 'invalid_file',
      });
      return;
    }

    String? targetPath;
    try {
      final home = Platform.environment['USERPROFILE'] ??
          Platform.environment['HOME'] ??
          Directory.systemTemp.path;
      final dir = Directory(
          '$home${Platform.pathSeparator}Downloads${Platform.pathSeparator}LigamentSupport');
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      targetPath = resolveNonCollidingFilePath(dir.path, dl.filename);
      final partFile = File('$targetPath.part');
      await partFile.writeAsBytes(result.bytes!, flush: true);
      await partFile.rename(targetPath);
      if (!kIsWeb && Platform.isWindows) {
        try {
          await File('$targetPath:Zone.Identifier')
              .writeAsString('[ZoneTransfer]\r\nZoneId=3\r\n');
        } catch (_) {}
      }
      _sendControlJson({
        'type': 'file_ack',
        'transfer_id': transferId,
        'ok': true,
      });
    } catch (_) {
      if (targetPath != null) {
        try {
          final partFile = File('$targetPath.part');
          if (await partFile.exists()) await partFile.delete();
        } catch (_) {}
      }
      _sendControlJson({
        'type': 'file_ack',
        'transfer_id': transferId,
        'ok': false,
      });
    }
  }

  Future<MediaStream> _captureScreen() async {
    final sources = await desktopCapturer
        .getSources(types: [SourceType.Screen])
        .timeout(const Duration(seconds: 20))
        .catchError((Object _) {
          throw const LinkHostReadinessException(
              'host_screen_capture_unavailable');
        });
    if (sources.isEmpty) {
      throw const LinkHostReadinessException('host_screen_capture_unavailable');
    }
    final source = sources.first;
    _selectedScreenId = source.id;
    _screenRect = InputInjector.instance.getMonitorRectForSource(source.id);
    InputInjector.instance.setActiveMonitorRect(_screenRect);
    try {
      return await _openDisplayStream(source.id);
    } catch (_) {
      throw const LinkHostReadinessException('host_screen_capture_unavailable');
    }
  }

  @override
  Future<void> addRemoteCandidate(Map<String, dynamic> candidate) async {
    final peer = _peer;
    if (peer == null || _closed) return;
    final value = candidate['candidate'];
    if (value is! String || value.isEmpty || value.length > 4096) {
      throw const FormatException('Invalid Link ICE candidate');
    }
    final mid = candidate['sdpMid'];
    final index = candidate['sdpMLineIndex'];
    if (mid != null && mid is! String ||
        index != null && (index is! int || index < 0 || index > 32)) {
      throw const FormatException('Invalid Link ICE candidate metadata');
    }
    await peer
        .addCandidate(RTCIceCandidate(value, mid as String?, index as int?));
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _connectionGraceTimer?.cancel();
    _connectionGraceTimer = null;
    _recorderFrameTimer?.cancel();
    _recorderFrameTimer = null;
    _activitySnapshotTimer?.cancel();
    _activitySnapshotTimer = null;
    _desktopSwitchTimer?.cancel();
    _desktopSwitchTimer = null;
    _desktopSwitchDebounceTimer?.cancel();
    _desktopSwitchDebounceTimer = null;
    _videoSender = null;
    _audioSender = null;
    InputInjector.instance.setKeepSessionAwake(false);
    for (final dl in _activeDownloads.values) {
      dl.stallTimer?.cancel();
    }
    _activeDownloads.clear();
    _pendingChatMessages.clear();
    final control = _control;
    _control = null;
    if (control != null) {
      control.onMessage = null;
      await control.close();
    }
    InputInjector.instance.setInputBlocked(false);
    InputInjector.instance.releaseAllPressed();
    InputInjector.instance.setActiveMonitorRect(null);
    final stream = _stream;
    _stream = null;
    if (stream != null) {
      for (final track in stream.getTracks()) {
        track.stop();
      }
      await stream.dispose();
    }
    final audioStream = _audioStream;
    _audioStream = null;
    if (audioStream != null && audioStream != stream) {
      for (final track in audioStream.getTracks()) {
        track.stop();
      }
      await audioStream.dispose();
    }
    final peer = _peer;
    _peer = null;
    if (peer != null) {
      peer.onIceCandidate = null;
      peer.onDataChannel = null;
      peer.onConnectionState = null;
      await peer.close();
      await peer.dispose();
    }
  }
}
