import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'input_injector.dart';
import 'link_host_readiness.dart';
import '../models/link_control_messages.dart';

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
    this.readyTimeout = const Duration(seconds: 20),
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
          (accessMode == 'control' &&
              !mediaLines.any((line) => line.startsWith('m=application ')))) {
        await _reject('invalid_offer_media');
        return;
      }
      final answer = await peer.start(
        offerSdp: offerSdp,
        iceServers: iceServers,
        allowControl: accessMode == 'control',
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
        final candidateValue = signal['candidate'];
        if (candidateValue is! Map) {
          await _reject('invalid_signal');
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
        } catch (_) {
          await _reject('invalid_candidate');
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
        'signal': {'candidate': candidate},
      });
    } catch (_) {
      await _reject('signaling_failed');
    }
  }

  Future<void> _reject(String reason) => _rejecting ??= _rejectOnce(reason);

  Future<void> _rejectOnce(String reason) async {
    if (_closed) return;
    // An accepted session has already been committed by the server. Do not
    // send a second session_answer; just release local media and input.
    if (_ready) {
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

  Future<void> get disconnectRequested => _disconnect.future;

  void showSession(String id, String mode, String operator,
      {String type = 'attended', int digits = 2}) {
    confirmationCode = '';
    sessionId = id;
    accessMode = mode;
    final trimmedOperator = operator.trim();
    operatorName = String.fromCharCodes(trimmedOperator.runes.take(96));
    accessType = type;
    confirmationDigits = digits;
    phase = LinkHostWorkerPhase.connecting;
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
    if (!RegExp(r'^(?:[0-9]{2}|[0-9]{3}|[0-9]{6})$').hasMatch(code) ||
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
    if (phase == LinkHostWorkerPhase.connecting) {
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
              !const [2, 3, 6].contains(confirmationDigits))) ||
      sdp is! String ||
      (operatorName != null &&
          (operatorName is! String || operatorName.runes.length > 128)) ||
      (iceRaw != null && iceRaw is! List)) {
    await unixTransport?.close();
    throw const FormatException('Invalid Link session offer bootstrap');
  }
  state.showSession(
    sessionId,
    accessMode,
    operatorName is String ? operatorName : '',
    type: accessType as String,
    digits: confirmationDigits is int ? confirmationDigits : 0,
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
  final session = LinkHostSession(
    sessionId: sessionId,
    accessMode: accessMode,
    peer: FlutterLinkHostPeer(onConnected: state.markActive),
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
        final message = jsonDecode(frame);
        if (message is Map) {
          await session.receive(Map<String, dynamic>.from(message));
        }
      }
    } catch (_) {
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

/// Flutter WebRTC peer implementation used by the interactive Link worker.
class FlutterLinkHostPeer implements LinkHostPeer {
  FlutterLinkHostPeer({this.onConnected});

  final VoidCallback? onConnected;

  RTCPeerConnection? _peer;
  MediaStream? _stream;
  RTCDataChannel? _control;
  ScreenRect? _screenRect;
  String? _selectedScreenId;
  bool _allowControl = false;
  bool _closed = false;

  Future<void> _sendScreenList() async {
    final control = _control;
    if (control == null || _closed) return;
    try {
      final sources =
          await desktopCapturer.getSources(types: [SourceType.Screen]);
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

  Future<void> switchScreen(String screenId) async {
    if (kIsWeb || _peer == null || _closed) return;
    try {
      final newStream =
          await navigator.mediaDevices.getDisplayMedia(<String, dynamic>{
        'audio': false,
        'video': {
          'deviceId': {'exact': screenId},
          'cursor': 'always',
        },
      });
      final oldTracks = _stream?.getVideoTracks() ?? [];
      final newTracks = newStream.getVideoTracks();
      if (newTracks.isNotEmpty && oldTracks.isNotEmpty) {
        final senders = await _peer!.getSenders();
        for (final sender in senders) {
          if (sender.track?.kind == 'video') {
            await sender.replaceTrack(newTracks.first);
            break;
          }
        }
        for (final t in oldTracks) {
          t.stop();
        }
        _stream = newStream;
        _selectedScreenId = screenId;
        _screenRect = InputInjector.instance.getMonitorRectForSource(screenId);
        InputInjector.instance.setActiveMonitorRect(_screenRect);
        await _sendScreenList();
      }
    } catch (e) {
      debugPrint('link_host_session: switchScreen failed: $e');
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
      if (!_allowControl ||
          (channel.label != 'link-control-v1' && channel.label != 'control') ||
          _control != null) {
        unawaited(channel.close());
        return;
      }
      _control = channel;
      channel.onDataChannelState = (state) {
        if (state == RTCDataChannelState.RTCDataChannelOpen) {
          _sendScreenList();
        } else if (state == RTCDataChannelState.RTCDataChannelClosed) {
          InputInjector.instance.releaseAllPressed();
        }
      };
      channel.onMessage = (message) {
        if (_closed || message.isBinary) return;
        try {
          final decoded = jsonDecode(message.text);
          if (decoded is Map) {
            final control = Map<String, dynamic>.from(decoded);
            if (_isValidInput(control)) _executeInput(control);
          }
        } on FormatException {
          // Malformed DTLS payloads are ignored; they never reach the injector.
        }
      };
    };
    peer.onConnectionState = (state) {
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        onConnected?.call();
      } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
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
    for (final track in capture.getVideoTracks()) {
      await peer.addTrack(track, capture);
    }
    final answer = await peer.createAnswer();
    await peer.setLocalDescription(answer);
    return answer.sdp ?? '';
  }

  static bool isValidInput(Map<String, dynamic> input) => _isValidInput(input);

  static bool _isValidInput(Map<String, dynamic> input) {
    final type = input['type'];
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
    return false;
  }

  void _executeInput(Map<String, dynamic> input) {
    if (!_allowControl || _closed) return;
    final injector = InputInjector.instance;
    final type = input['type'];
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
      } else if (type == 'screen_list') {
        _sendScreenList();
      } else if (type == 'switch_screen') {
        final screenId = input['screen_id']?.toString();
        if (screenId != null) {
          switchScreen(screenId);
        }
      } else if (type == 'clipboard_set') {
        final text = input['text']?.toString() ?? '';
        if (text.length <= 65536) {
          Clipboard.setData(ClipboardData(text: text));
        }
      } else if (type == 'clipboard_get') {
        Clipboard.getData(Clipboard.kTextPlain).then((clip) {
          final text = clip?.text ?? '';
          _control?.send(RTCDataChannelMessage(jsonEncode({
            'type': 'clipboard_data',
            'text': text,
          })));
        });
      } else if (type == 'block_input') {
        injector.setInputBlocked(input['blocked'] == true);
      }
    } catch (_) {
      _control?.send(RTCDataChannelMessage(jsonEncode({
        'type': 'input_error',
      })));
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
      return await navigator.mediaDevices.getDisplayMedia({
        'audio': false,
        'video': {
          'deviceId': {'exact': source.id},
          'cursor': 'always',
        },
      }).timeout(const Duration(seconds: 30));
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
    final control = _control;
    _control = null;
    if (control != null) {
      control.onMessage = null;
      await control.close();
    }
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
