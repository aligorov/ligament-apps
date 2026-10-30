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
import 'link_spool_storage.dart';
import 'debug_log_service.dart';
import 'support_service.dart'
    show
        SupportChatMessage,
        assembleFileChunks,
        resolveNonCollidingFilePath,
        supportDebugMessageType;
import '../models/link_control_messages.dart';
import '../models/link_session_policy.dart';

void _linkLog(String event,
        {Object? error, Map<String, Object?> fields = const {}}) =>
    DebugLogService.instance.record(event, error: error, fields: {
      ...fields,
      if (fields.containsKey('reason'))
        'reason': DebugLogService.protocolLabel(fields['reason']),
    });

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
    DebugLogService? debugLog,
  }) : _debugLog = debugLog ?? DebugLogService.instance {
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
  final DebugLogService _debugLog;

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

  void _sessionLog(String event,
      {Object? error, Map<String, Object?> fields = const {}}) {
    _debugLog.record(event, error: error, fields: {
      'session_id': sessionId,
      'state': _closed
          ? 'closed'
          : _ready
              ? 'ready'
              : 'starting',
      'candidates': _pendingCandidates.length,
      ...fields,
      if (fields.containsKey('reason'))
        'reason': DebugLogService.protocolLabel(fields['reason']),
    });
  }

  Future<void> _sendFrame(Map<String, dynamic> frame) async {
    final watch = Stopwatch()..start();
    final fields = <String, Object?>{
      'message_type': supportDebugMessageType(frame['type']),
      'operation': 'send',
    };
    _sessionLog('link.signal.outbound', fields: {...fields, 'result': 'begin'});
    try {
      await send(frame);
      _sessionLog('link.signal.outbound', fields: {
        ...fields,
        'result': 'queued',
        'duration_ms': watch.elapsedMilliseconds,
      });
    } catch (error) {
      _sessionLog('link.signal.outbound', error: error, fields: {
        ...fields,
        'result': 'failed',
        'duration_ms': watch.elapsedMilliseconds,
      });
      rethrow;
    }
  }

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
    final watch = Stopwatch()..start();
    var phase = 'authorization';
    _sessionLog('link.start', fields: {
      'phase': phase,
      'result': 'begin',
      'ice_servers': iceServers.length
    });
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
        await _sendFrame({
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
        _sessionLog('link.authorization', fields: {
          'result': authorized ? 'allowed' : 'denied',
          'duration_ms': watch.elapsedMilliseconds,
        });
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
      phase = 'peer_start';
      watch.reset();
      _sessionLog('link.peer.start',
          fields: {'phase': phase, 'result': 'begin'});
      final answer = await peer.start(
        offerSdp: offerSdp,
        iceServers: iceServers,
        allowControl: accessMode == 'control' || accessMode == 'full_control',
        onCandidate: (candidate) => unawaited(_sendCandidate(candidate)),
        onFailure: () => unawaited(_reject('host_media_failed')),
      );
      if (_closed) return;
      _sessionLog('link.peer.answer_ready',
          fields: {'duration_ms': watch.elapsedMilliseconds});
      phase = 'answer_send';
      if (answer.isEmpty || utf8.encode(answer).length > maxOfferSdpBytes) {
        throw const FormatException('Invalid Link answer SDP');
      }
      await _sendFrame({
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
      _sessionLog('link.session.ready', fields: {'result': 'ready'});
      _readyTimer?.cancel();
      for (final candidate
          in List<Map<String, dynamic>>.of(_pendingCandidates)) {
        await peer.addRemoteCandidate(candidate);
        _sessionLog('link.candidate',
            fields: {'result': 'applied', 'candidates': 1});
      }
      _pendingCandidates.clear();
    } on LinkHostReadinessException catch (error) {
      _sessionLog('link.start.failed', error: error, fields: {
        'phase': phase,
        'reason': error.reason,
        'duration_ms': watch.elapsedMilliseconds
      });
      _linkLog('link.exception',
          error: error, fields: {'phase': 'start', 'result': 'failed'});
      await _reject(error.reason);
    } catch (error) {
      _linkLog('link.exception',
          error: error, fields: {'phase': 'start', 'result': 'failed'});
      _sessionLog('link.start.failed',
          error: error,
          fields: {'phase': phase, 'duration_ms': watch.elapsedMilliseconds});
      await _reject('host_worker_failed');
    }
  }

  Future<void> receive(Map<String, dynamic> frame) async {
    if (_closed) return;
    _sessionLog('link.signal.inbound',
        fields: {'message_type': supportDebugMessageType(frame['type'])});
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
        _sessionLog('link.signal.dispatch',
            fields: {'message_type': supportDebugMessageType(signal['type'])});
        if (signal['type'] == 'consent_decision') {
          if (_authorization?.isCompleted == false &&
              _consentNonce != null &&
              signal['consent_nonce'] == _consentNonce) {
            _sessionLog('link.authorization.decision', fields: {
              'result': signal['authorized'] == true ? 'allowed' : 'denied'
            });
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
                await _sendFrame({
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
              _linkLog('link.exception',
                  error: e, fields: {'phase': 'receive', 'result': 'failed'});
            }
          }
          return;
        }
        final candidateValue = signal['candidate'];
        if (candidateValue is! Map) {
          return;
        }
        final candidate = Map<String, dynamic>.from(candidateValue);
        if (!_ready) {
          if (_pendingCandidates.length >= maxPendingCandidates) {
            await _reject('candidate_queue_full');
            return;
          }
          _pendingCandidates.add(candidate);
          _sessionLog('link.candidate', fields: {'result': 'queued'});
          return;
        }
        try {
          await peer.addRemoteCandidate(candidate);
          _sessionLog('link.candidate',
              fields: {'result': 'applied', 'candidates': 1});
        } catch (e) {
          _linkLog('link.exception',
              error: e, fields: {'phase': 'receive', 'result': 'failed'});
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
      await _sendFrame({
        'type': 'signal',
        'session_id': sessionId,
        'signal': {'type': 'candidate', 'candidate': candidate},
      });
    } catch (error) {
      _linkLog('link.exception',
          error: error,
          fields: {'phase': 'send_candidate', 'result': 'failed'});
      await _reject('signaling_failed');
    }
  }

  Future<void> _reject(String reason) => _rejecting ??= _rejectOnce(reason);

  Future<void> _rejectOnce(String reason) async {
    if (_closed) return;
    _sessionLog('link.reject',
        fields: {'reason': reason, 'result': 'stopping'});
    // An accepted session has already been committed by the server. Notify
    // the server with session_terminate so the operator does not freeze.
    if (_ready) {
      if (reason != 'invalid_session_scope') {
        try {
          await _sendFrame({
            'type': 'session_terminate',
            'session_id': sessionId,
            'payload': {
              'session_id': sessionId,
              'reason': reason,
            },
          });
        } catch (error) {
          _linkLog('link.exception',
              error: error,
              fields: {'phase': 'reject_once', 'result': 'failed'});
        }
      }
      await close();
      return;
    }
    try {
      await _sendFrame({
        'type': 'session_answer',
        'session_id': sessionId,
        'payload': {
          'session_id': sessionId,
          'accepted': false,
          'reason': reason,
        },
      });
    } catch (error) {
      _linkLog('link.exception',
          error: error, fields: {'phase': 'reject_once', 'result': 'failed'});
    }
    await close();
  }

  Future<void> reject(String reason) => _reject(reason);

  Future<void> close() {
    final existing = _closing;
    if (existing != null) return existing;
    _sessionLog('link.close', fields: {'result': 'begin'});
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
  bool _consentUiAvailable = true;

  bool get consentUiAvailable => _consentUiAvailable;

  void markConsentUiUnavailable() {
    _consentUiAvailable = false;
    if (_consent?.isCompleted == false) _consent!.complete(false);
    if (phase == LinkHostWorkerPhase.awaitingConsent) {
      phase = LinkHostWorkerPhase.closing;
      notifyListeners();
    }
  }

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
    if (_consent?.isCompleted == false) _consent!.complete(false);
    _consent = null;
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
    if (_disconnect.isCompleted ||
        phase == LinkHostWorkerPhase.closing ||
        phase == LinkHostWorkerPhase.closed ||
        !_consentUiAvailable) {
      return Future<bool>.value(false);
    }
    final pending = _consent;
    if (pending != null) return pending.future;
    final consent = _consent = Completer<bool>();
    phase = LinkHostWorkerPhase.awaitingConsent;
    notifyListeners();
    return consent.future.timeout(
      const Duration(seconds: 45),
      onTimeout: () {
        if (identical(_consent, consent)) denyConsent();
        return false;
      },
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
      _linkLog('link.exception',
          error: e,
          fields: {'phase': 'receive_chat_message', 'result': 'failed'});
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
    _linkLog('link.ipc.unix.send', fields: {
      'operation': 'send',
      'transport': 'unix',
      'session_id': frame['session_id'],
      'message_type': supportDebugMessageType(frame['type']),
      'bytes': payload.length,
      'result': 'queued',
    });
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
  } catch (error) {
    _linkLog('link.worker.failed', error: error, fields: {'phase': 'worker'});
    rethrow;
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
  DebugLogService.instance.record('link.ipc.bootstrap.begin');
  try {
    rawBootstrap = unixTransport == null
        ? await LinkHostSession._nativeChannel
                .invokeMethod<String>('bootstrap', endpoint)
                .timeout(const Duration(seconds: 10)) ??
            ''
        : utf8.decode(await unixTransport.receive().timeout(
              const Duration(seconds: 10),
            ));
  } catch (error) {
    _linkLog('link.exception', error: error, fields: {
      'phase': 'run_connected_link_host_worker',
      'result': 'failed'
    });
    await unixTransport?.close();
    rethrow;
  }
  _linkLog('link.ipc.bootstrap.received', fields: {
    'operation': 'bootstrap',
    'bytes': utf8.encode(rawBootstrap).length
  });
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
  _linkLog('link.ipc.bootstrap.parsed', fields: {
    'operation': 'bootstrap',
    'session_id': sessionId,
    'result': 'validated'
  });
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
          spool: recordingConfig.spoolEnabled
              ? LinkSpoolStorage(
                  sessionId: sessionId,
                  maxSpoolBytes: recordingConfig.maxSpoolBytes,
                )
              : null,
          onMandatoryViolation: (reason) => unawaited(session.reject(reason)),
        )
      : null;
  // Немедленно активируем recorder при наличии настроек записи,
  // чтобы session_start сразу отправился на сервер и продлил аренду сессии.
  if (recordingConfig.isActive) {
    recorder?.start();
  }
  final peer = FlutterLinkHostPeer(
    debugSessionId: sessionId,
    onConnected: () {
      DebugLogService.instance.record('link.session.connected');
      state.markActive();
      recorder?.start();
    },
    isRecorderReady: () =>
        recorder == null ||
        (!recorder.config.mandatory && !recorder.config.requireFirstFrame) ||
        !recorder.config.isStrict ||
        recorder.firstFrameAcked,
    onControlInputObserved: recorder?.observeControlInput,
    onDesktopChanged: recorder?.notifyDesktopChanged,
    onChatMessageReceived: state.receiveChatMessage,
    onFrameCaptured: recorder == null
        ? null
        : (kind, bytes, monitorId) async {
            final frameInfo = await prepareRecordedFrame(bytes);
            if (frameInfo != null) {
              final enqueued = recorder.enqueueFrame(
                frameKind: kind,
                payload: frameInfo.payload,
                monitorId: monitorId,
                width: frameInfo.width,
                height: frameInfo.height,
                codec: frameInfo.codec,
              );
              if (!enqueued) {
                DebugLogService.instance.record('link.recorder.enqueue_failed',
                    fields: {
                      'kind': kind,
                      'codec': frameInfo.codec,
                      'bytes': frameInfo.payload.length,
                    });
              }
            } else {
              DebugLogService.instance.record('link.recorder.prepare_failed',
                  fields: {
                    'kind': kind,
                    'raw_bytes': bytes.length,
                  });
            }
          },
    policy: LinkSessionPolicy.fromWire(
      offer['dlp'],
      desktopScope: offer['desktop_scope']?.toString(),
    ),
    recordingConfig: recordingConfig,
  );
  state.bindChatSender(peer.sendChatMessage);
  session = LinkHostSession(
    sessionId: sessionId,
    accessMode: accessMode,
    peer: peer,
    send: (frame) {
      final fields = <String, Object?>{
        'operation': 'send',
        'session_id': sessionId,
        'message_type': supportDebugMessageType(frame['type']),
      };
      _linkLog('link.ipc.outbound', fields: {...fields, 'result': 'queued'});
      final next = outgoing.then((_) async {
        _linkLog('link.ipc.outbound', fields: {...fields, 'result': 'begin'});
        try {
          if (unixTransport != null) {
            await unixTransport.send(frame);
          } else {
            final text = jsonEncode(frame);
            fields['bytes'] = utf8.encode(text).length;
            final accepted = await LinkHostSession._nativeChannel
                .invokeMethod<bool>('send', text);
            if (accepted != true) {
              throw StateError('Link worker pipe rejected frame');
            }
          }
          _linkLog('link.ipc.outbound',
              fields: {...fields, 'result': 'accepted'});
        } catch (error) {
          _linkLog('link.ipc.outbound',
              error: error, fields: {...fields, 'result': 'failed'});
          rethrow;
        }
      });
      outgoing = next;
      return next;
    },
  );
  _linkLog('link.ipc.bootstrap.validated', fields: {
    'session_id': sessionId,
    'operation': 'bootstrap',
    'ice_servers': iceServers.length,
    'result': 'validated'
  });
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
        _linkLog('link.ipc.inbound', fields: {
          'operation': 'receive',
          'bytes': utf8.encode(frame).length,
          'session_id': sessionId
        });
        try {
          final message = jsonDecode(frame);
          if (message is Map) {
            await session.receive(Map<String, dynamic>.from(message));
          }
        } on FormatException catch (e) {
          _linkLog('link.exception', error: e, fields: {
            'phase': 'run_connected_link_host_worker',
            'result': 'failed'
          });
        } catch (e) {
          _linkLog('link.exception', error: e, fields: {
            'phase': 'run_connected_link_host_worker',
            'result': 'failed'
          });
        }
      }
    } catch (e) {
      _linkLog('link.exception', error: e, fields: {
        'phase': 'run_connected_link_host_worker',
        'result': 'failed'
      });
      DebugLogService.instance.record('link.ipc.failed', error: e);

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
    if (accessType == 'attended') {
      DebugLogService.instance.record(
          consentGranted ? 'link.consent.allowed' : 'link.consent.denied');
    }
    if (session.isClosed ||
        state.phase == LinkHostWorkerPhase.closing ||
        (accessType == 'attended' && !consentGranted)) {
      if (!session.isClosed) {
        await session.reject(
            accessType == 'attended' && !state.consentUiAvailable
                ? 'host_ui_unavailable'
                : 'host_consent_denied');
      }
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
      } catch (error) {
        _linkLog('link.exception', error: error, fields: {
          'phase': 'run_connected_link_host_worker',
          'result': 'failed'
        });
      }
    }
  } finally {
    timer.cancel();
    DebugLogService.instance.record('link.shutdown.begin');
    final isTailFlushed = await recorder?.stop(reason: 'session_ended') ?? true;
    DebugLogService.instance.record(
        isTailFlushed ? 'link.recorder.tail_saved' : 'link.recorder.tail_spooled');
    if (!isTailFlushed) {
      try {
        await session.reject('recorder_tail_lost');
      } catch (_) {}
    }
    await session.close();
    if (unixTransport != null) {
      await unixTransport.close();
    } else {
      try {
        await LinkHostSession._nativeChannel.invokeMethod<void>('close');
      } catch (error) {
        _linkLog('link.exception', error: error, fields: {
          'phase': 'run_connected_link_host_worker',
          'result': 'failed'
        });
      }
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
    this.debugSessionId,
    this.onConnected,
    this.onControlInputObserved,
    this.onDesktopChanged,
    this.onChatMessageReceived,
    this.onFrameCaptured,
    this.isRecorderReady,
    this.policy = const LinkSessionPolicy(),
    this.recordingConfig,
  });

  static const Duration connectionGracePeriod = Duration(seconds: 60);
  static const int _maxFileTransferBytes = 50 * 1024 * 1024;
  static const int _maxConcurrentDownloads = 4;
  static const Duration _downloadStallTimeout = Duration(seconds: 30);

  final String? debugSessionId;
  final VoidCallback? onConnected;

  void _peerLog(String event,
      {Object? error, Map<String, Object?> fields = const {}}) {
    _linkLog(event, error: error, fields: {
      'session_id': debugSessionId,
      'state': _closed ? 'closed' : 'open',
      'control_ready': _allowControl &&
          _control?.state == RTCDataChannelState.RTCDataChannelOpen,
      'tracks': _stream?.getTracks().length ?? 0,
      ...fields,
    });
  }

  void _observeDataEnqueue(Future<void> send, String type, int bytes) {
    _peerLog('link.data.outbound',
        fields: {'message_type': type, 'bytes': bytes, 'result': 'requested'});
    unawaited(send.then((_) {
      _peerLog('link.data.outbound',
          fields: {'message_type': type, 'bytes': bytes, 'result': 'queued'});
    }).catchError((Object error) {
      _peerLog('link.data.outbound',
          error: error,
          fields: {'message_type': type, 'bytes': bytes, 'result': 'failed'});
    }));
  }

  Future<T> _peerStep<T>(String phase, Future<T> Function() action) async {
    final watch = Stopwatch()..start();
    _peerLog('link.peer.step', fields: {'phase': phase, 'result': 'begin'});
    try {
      final result = await action();
      _peerLog('link.peer.step', fields: {
        'phase': phase,
        'result': 'ready',
        'duration_ms': watch.elapsedMilliseconds
      });
      return result;
    } catch (error) {
      _peerLog('link.peer.step', error: error, fields: {
        'phase': phase,
        'result': 'failed',
        'duration_ms': watch.elapsedMilliseconds
      });
      rethrow;
    }
  }

  final void Function(Map<String, dynamic> input)? onControlInputObserved;
  final void Function()? onDesktopChanged;
  final void Function(Map<String, dynamic> message)? onChatMessageReceived;
  final void Function(String frameKind, Uint8List bytes, String monitorId)?
      onFrameCaptured;
  final bool Function()? isRecorderReady;
  final LinkSessionPolicy policy;
  final LinkRecordingConfig? recordingConfig;

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
  int _mouseMessages = 0;
  int _mouseBytes = 0;
  int _mousePolicyBlocked = 0;
  int _mouseRecorderBlocked = 0;
  Timer? _mouseSummaryTimer;
  void _observeInbound(Map<String, dynamic> message, int bytes) {
    final type = supportDebugMessageType(message['type']);
    if (type == 'mouse_move') {
      _mouseMessages++;
      _mouseBytes += bytes;
      _mouseSummaryTimer ??=
          Timer(const Duration(seconds: 1), _flushMouseSummary);
      return;
    }
    _peerLog('link.data.inbound',
        fields: {'message_type': type, 'bytes': bytes});
  }

  void _flushMouseSummary() {
    _mouseSummaryTimer?.cancel();
    _mouseSummaryTimer = null;
    if (_mouseMessages > 0) {
      _peerLog('link.data.mouse_summary', fields: {
        'message_type': 'mouse_move',
        'count': _mouseMessages,
        'bytes': _mouseBytes,
      });
    }
    if (_mousePolicyBlocked > 0) {
      _peerLog('link.input.gate_summary', fields: {
        'message_type': 'mouse_move',
        'reason': 'policy',
        'result': 'blocked',
        'count': _mousePolicyBlocked
      });
    }
    if (_mouseRecorderBlocked > 0) {
      _peerLog('link.input.gate_summary', fields: {
        'message_type': 'mouse_move',
        'reason': 'recorder_not_ready',
        'result': 'blocked',
        'count': _mouseRecorderBlocked
      });
    }
    _mouseMessages = 0;
    _mouseBytes = 0;
    _mousePolicyBlocked = 0;
    _mouseRecorderBlocked = 0;
  }

  bool _allowControl = false;
  bool _closed = false;

  Future<void> _captureRecorderSnapshot(String frameKind) async {
    final cb = onFrameCaptured;
    if (cb == null || _closed || _capturingFrame || _switchingScreen) return;
    _capturingFrame = true;
    try {
      Uint8List? bytes;
      String currentMonitorId = _selectedScreenId ?? '0';

      // 1. Приоритетный захват на Windows через Win32 GDI (не конфликтует с DXGI exclusive duplication)
      if (!kIsWeb && Platform.isWindows) {
        try {
          final targetRect = _screenRect ??
              InputInjector.instance.getMonitorRectForSource(currentMonitorId) ??
              InputInjector.instance.activeMonitorRect;
          bytes = InputInjector.instance
              .captureDesktopBmp(maxWidth: 1280, maxHeight: 720, rect: targetRect);
        } catch (error) {
          _peerLog('link.exception', error: error, fields: {
            'phase': 'capture_recorder_snapshot_gdi',
            'result': 'failed'
          });
        }
      }

      // 2. Штатный запрос миниатюры через WebRTC (macOS/Linux или фоллбэк)
      if (bytes == null && !_closed) {
        if (_selectedScreenId == null) {
          try {
            final sources = await desktopCapturer.getSources(
                types: [SourceType.Screen]).timeout(const Duration(seconds: 3));
            if (sources.isNotEmpty) {
              _selectedScreenId = sources.first.id;
              currentMonitorId = sources.first.id;
            }
          } catch (error) {
            _peerLog('link.exception', error: error, fields: {
              'phase': 'capture_recorder_snapshot',
              'result': 'failed'
            });
          }
        }

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
        } catch (error) {
          _peerLog('link.exception',
              error: error,
              fields: {'phase': 'capture_recorder_snapshot', 'result': 'failed'});
        }
      }

      // NOTE: Never fall back to `tracks.first.captureFrame()` on desktop:
      // flutter_webrtc's C++ FlutterFrameCapturer::CaptureFrame executes a
      // synchronous `while(!catch_frame_){}` busy-wait on the Win32 UI thread,
      // which deadlocks at 100% CPU during Winlogon -> Default transitions.
      if (bytes != null && bytes.isNotEmpty && !_closed) {
        _lastFrameCaptureAt = DateTime.now();
        cb(frameKind, bytes, currentMonitorId);
      } else if (!_closed) {
        _peerLog('link.capture.snapshot_unavailable', fields: {
          'phase': 'recorder_snapshot',
          'reason': 'empty_capture',
          'result': 'failed'
        });
      }
    } catch (error) {
      _peerLog('link.exception',
          error: error,
          fields: {'phase': 'capture_recorder_snapshot', 'result': 'failed'});
    } finally {
      _capturingFrame = false;
    }
  }

  Future<void> _sendScreenList() async {
    final control = _control;
    if (control == null || _closed) return;
    try {
      final sources = await desktopCapturer.getSources(
          types: [SourceType.Screen]).timeout(const Duration(seconds: 10));
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
      final text = jsonEncode(payload);
      _observeDataEnqueue(control.send(RTCDataChannelMessage(text)),
          supportDebugMessageType(payload['type']), utf8.encode(text).length);
      _peerLog('link.capture.screens', fields: {'count': screens.length});
    } catch (e) {
      _peerLog('link.exception',
          error: e, fields: {'phase': 'send_screen_list', 'result': 'failed'});
    }
  }

  Future<MediaStream> _openDisplayStream(String sourceId,
      {bool withAudio = true}) async {
    final videoConstraintsExact = <String, dynamic>{
      'deviceId': {'exact': sourceId},
      'cursor': 'always',
    };
    final videoConstraintsPlain = <String, dynamic>{
      'deviceId': sourceId,
      'cursor': 'always',
    };
    final wantLoopbackAudio =
        withAudio && !kIsWeb && (Platform.isWindows || Platform.isLinux);
    MediaStream? stream;
    if (wantLoopbackAudio) {
      try {
        stream = await navigator.mediaDevices.getDisplayMedia(<String, dynamic>{
          'audio': true,
          'video': videoConstraintsExact,
        }).timeout(const Duration(seconds: 10));
        final audioCount = stream.getAudioTracks().length;
        _peerLog('link.capture.audio',
            fields: {'tracks': audioCount, 'result': 'ready'});
      } catch (e) {
        _peerLog('link.exception',
            error: e,
            fields: {'phase': 'open_display_stream', 'result': 'failed'});
        try {
          stream = await navigator.mediaDevices.getDisplayMedia(<String, dynamic>{
            'audio': true,
            'video': videoConstraintsPlain,
          }).timeout(const Duration(seconds: 10));
          final audioCount = stream.getAudioTracks().length;
          _peerLog('link.capture.audio',
              fields: {'tracks': audioCount, 'result': 'ready_fallback'});
        } catch (_) {}
      }
    }
    if (stream == null) {
      try {
        stream = await navigator.mediaDevices.getDisplayMedia(<String, dynamic>{
          'audio': false,
          'video': videoConstraintsExact,
        }).timeout(const Duration(seconds: 10));
      } catch (_) {
        stream = await navigator.mediaDevices.getDisplayMedia(<String, dynamic>{
          'audio': false,
          'video': videoConstraintsPlain,
        }).timeout(const Duration(seconds: 10));
      }
    }
    return stream;
  }

  Future<MediaStream?> _acquireAudioStream() async {
    if (kIsWeb) return null;
    try {
      final devices = await navigator.mediaDevices.enumerateDevices();
      String? loopbackDeviceId;
      for (final device in devices) {
        if (device.kind == 'audioinput') {
          final label = device.label.toLowerCase();
          if (label.contains('stereo mix') ||
              label.contains('стерео микшер') ||
              label.contains('стереомикшер') ||
              label.contains('loopback') ||
              label.contains('what u hear') ||
              label.contains('wave out') ||
              label.contains('blackhole') ||
              label.contains('soundflower')) {
            loopbackDeviceId = device.deviceId;
            break;
          }
        }
      }
      if (loopbackDeviceId != null && loopbackDeviceId.isNotEmpty) {
        final loopback =
            await navigator.mediaDevices.getUserMedia(<String, dynamic>{
          'audio': {
            'deviceId': loopbackDeviceId,
            'optional': [
              {'sourceId': loopbackDeviceId},
              {'echoCancellation': false},
              {'googEchoCancellation': false},
              {'googAutoGainControl': false},
              {'googNoiseSuppression': false},
              {'googHighpassFilter': false},
            ],
          },
          'video': false,
        }).timeout(const Duration(seconds: 3));
        if (loopback.getAudioTracks().isNotEmpty) {
          _peerLog('link.capture.audio', fields: {
            'tracks': loopback.getAudioTracks().length,
            'source': 'loopback_device',
            'result': 'ready'
          });
          return loopback;
        }
      }
    } catch (e) {
      _peerLog('link.exception',
          error: e, fields: {'phase': 'acquire_audio', 'result': 'failed'});
    }

    try {
      final defaultAudio =
          await navigator.mediaDevices.getUserMedia(<String, dynamic>{
        'audio': true,
        'video': false,
      }).timeout(const Duration(seconds: 3));
      if (defaultAudio.getAudioTracks().isNotEmpty) {
        _peerLog('link.capture.audio', fields: {
          'tracks': defaultAudio.getAudioTracks().length,
          'source': 'default_audio_input',
          'result': 'ready'
        });
        return defaultAudio;
      }
    } catch (e) {
      _peerLog('link.exception',
          error: e,
          fields: {'phase': 'acquire_default_audio', 'result': 'failed'});
    }

    return null;
  }

  Future<void> switchScreen(String screenId) async {
    if (kIsWeb || _peer == null || _closed) return;
    if (_switchingScreen) {
      _pendingScreenSwitch = true;
      _pendingScreenId = screenId;
      return;
    }
    _switchingScreen = true;
    _peerLog('link.capture.switch',
        fields: {'result': 'begin', 'screen_id': screenId});
    try {
      var targetScreenId = screenId;
      MediaStream? newStream;
      final needAudio =
          _audioStream == null || _audioStream!.getAudioTracks().isEmpty;

      // 1. Пытаемся разрешить targetScreenId через desktopCapturer sources (если доступно)
      try {
        final sources = await desktopCapturer
            .getSources(types: [SourceType.Screen])
            .timeout(const Duration(seconds: 5));
        if (sources.isNotEmpty) {
          DesktopCapturerSource? matched;
          for (final s in sources) {
            if (s.id == targetScreenId || s.id.trim() == targetScreenId.trim()) {
              matched = s;
              break;
            }
          }
          if (matched == null) {
            final requestedHandles =
                InputInjector.instance.parseSourceHandles(targetScreenId);
            for (final s in sources) {
              final sHandles =
                  InputInjector.instance.parseSourceHandles(s.id);
              if (requestedHandles.isNotEmpty &&
                  sHandles.isNotEmpty &&
                  requestedHandles.first == sHandles.first) {
                matched = s;
                break;
              }
            }
          }
          if (matched == null) {
            final idx = int.tryParse(targetScreenId);
            if (idx != null && idx >= 0 && idx < sources.length) {
              matched = sources[idx];
            }
          }
          if (matched != null) {
            targetScreenId = matched.id;
          }
        }
      } catch (e) {
        _peerLog('link.exception',
            error: e,
            fields: {'phase': 'switch_screen_resolve', 'result': 'failed'});
      }

      const backoffs = [100, 250, 500, 1000];
      final startTime = DateTime.now();
      var attempt = 0;

      while (
          DateTime.now().difference(startTime) < const Duration(seconds: 10)) {
        if (_closed || _peer == null) return;
        try {
          newStream =
              await _openDisplayStream(targetScreenId, withAudio: needAudio);
          if (newStream.getVideoTracks().isNotEmpty) {
            break;
          }
        } catch (e) {
          _peerLog('link.exception',
              error: e, fields: {'phase': 'switch_screen', 'result': 'failed'});
        }
        final delayMs = attempt < backoffs.length ? backoffs[attempt] : 1000;
        attempt++;
        if (DateTime.now().difference(startTime) +
                Duration(milliseconds: delayMs) >=
            const Duration(seconds: 10)) {
          break;
        }
        await Future<void>.delayed(Duration(milliseconds: delayMs));
      }

      if (newStream == null) {
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
        final newTrack = newVideoTracks.first;
        if (_videoSender != null) {
          await _videoSender!.replaceTrack(newTrack);
        } else {
          final senders = await _peer!.getSenders();
          for (final sender in senders) {
            if (sender.track?.kind == 'video') {
              _videoSender = sender;
              await sender.replaceTrack(newTrack);
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
      } else if (_audioStream == null || _audioStream!.getAudioTracks().isEmpty) {
        final audioCapture = await _acquireAudioStream();
        if (audioCapture != null && audioCapture.getAudioTracks().isNotEmpty) {
          _audioStream = audioCapture;
          final track = audioCapture.getAudioTracks().first;
          await newStream.addTrack(track, addToNative: false);
          if (_audioSender != null) {
            await _audioSender!.replaceTrack(track);
          } else {
            final senders = await _peer!.getSenders();
            for (final sender in senders) {
              if (sender.track?.kind == 'audio') {
                _audioSender = sender;
                await sender.replaceTrack(track);
                break;
              }
            }
            if (_audioSender == null && _peer != null) {
              _audioSender = await _peer!.addTrack(track, newStream);
            }
          }
        }
      } else if (_audioStream != null && _audioStream!.getAudioTracks().isNotEmpty) {
        final track = _audioStream!.getAudioTracks().first;
        await newStream.addTrack(track, addToNative: false);
      }

      final oldStream = _stream;
      _stream = newStream;
      _selectedScreenId = targetScreenId;

      if (oldStream != null) {
        // Останавливаем только видеотреки старого потока, сохраняя системное аудио ПК
        for (final t in oldStream.getVideoTracks()) {
          try {
            await t.stop();
          } catch (error) {
            _peerLog('link.exception',
                error: error,
                fields: {'phase': 'switch_screen', 'result': 'failed'});
          }
        }
        if (oldStream != _audioStream) {
          try {
            await oldStream.dispose();
          } catch (error) {
            _peerLog('link.exception',
                error: error,
                fields: {'phase': 'switch_screen', 'result': 'failed'});
          }
        }
      }

      _screenRect =
          InputInjector.instance.getMonitorRectForSource(targetScreenId);
      InputInjector.instance.setActiveMonitorRect(_screenRect);
      _peerLog('link.capture.monitor',
          fields: {'screen_id': targetScreenId, 'width': _screenRect?.width, 'height': _screenRect?.height});

      final control = _control;
      if (control != null && !_closed) {
        final ack = {
          'type': 'screen_switched',
          'screen_id': targetScreenId,
          if (_screenRect != null) 'rect': _screenRect!.toJson(),
        };
        final text = jsonEncode(ack);
        try {
          _observeDataEnqueue(control.send(RTCDataChannelMessage(text)),
              supportDebugMessageType(ack['type']), utf8.encode(text).length);
        } catch (e) {
          _peerLog('link.exception',
              error: e, fields: {'phase': 'send_screen_switched'});
        }
      }
      await _sendScreenList();
      unawaited(_captureRecorderSnapshot('keyframe'));
    } catch (e) {
      _peerLog('link.exception',
          error: e, fields: {'phase': 'switch_screen', 'result': 'failed'});
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
    await _peerStep('input_ready',
        () => ensureLinkHostInputReady(allowControl: allowControl));
    InputInjector.instance.setDesktopScope(policy.desktopScope);
    final peer = await _peerStep(
        'peer_create',
        () => createPeerConnection({
              'iceServers': iceServers,
              'sdpSemantics': 'unified-plan',
            }));
    _peer = peer;
    var peerConnected = false;
    void markPeerConnected(String origin) {
      if (peerConnected || _closed) return;
      peerConnected = true;
      _peerLog('link.connected', fields: {'origin': origin});
      _connectionGraceTimer?.cancel();
      _connectionGraceTimer = null;
      InputInjector.instance.setKeepSessionAwake(true);
      if (!kIsWeb && Platform.isWindows) {
        _desktopSwitchTimer?.cancel();
        _desktopSwitchTimer = Timer.periodic(
          const Duration(milliseconds: 200),
          (_) {
            if (!_closed && InputInjector.instance.consumeDesktopChanged()) {
              _peerLog('link.desktop.changed', fields: {'origin': 'desktop'});
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
        final interval = recordingConfig?.frameInterval ?? const Duration(seconds: 1);
        _recorderFrameTimer = Timer.periodic(
          interval,
          (_) {
            unawaited(_captureRecorderSnapshot('periodic'));
          },
        );
      }
    }

    peer.onIceGatheringState = (state) =>
        _peerLog('link.ice.gathering', fields: {'ice_state': state.name});
    peer.onIceConnectionState = (state) {
      _peerLog('link.ice.state', fields: {'ice_state': state.name});
      if (state == RTCIceConnectionState.RTCIceConnectionStateConnected ||
          state == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
        markPeerConnected('ice_state');
      }
    };
    peer.onTrack = (event) => _peerLog('link.track.remote', fields: {
          'phase': event.track.kind == 'audio'
              ? 'audio'
              : event.track.kind == 'video'
                  ? 'video'
                  : 'unknown',
          'count': event.streams.length
        });
    peer.onIceCandidate = (candidate) {
      if (_closed ||
          candidate.candidate == null ||
          candidate.candidate!.isEmpty) {
        return;
      }
      _peerLog('link.candidate.local',
          fields: {'candidates': 1, 'result': 'generated'});
      onCandidate(Map<String, dynamic>.from(candidate.toMap()));
    };
    peer.onDataChannel = (channel) {
      _peerLog('link.dc.received', fields: {
        'result':
            (channel.label == 'link-control-v1' || channel.label == 'control')
                ? 'accepted'
                : 'rejected'
      });
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
        _peerLog('link.dc.state', fields: {'dc_state': state.name});
        if (state == RTCDataChannelState.RTCDataChannelOpen) {
          markPeerConnected('data_channel');
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
            _observeInbound(control, utf8.encode(message.text).length);
            if (control['type'] == 'ping') {
              try {
                final text = jsonEncode({
                  'type': 'pong',
                  'timestamp': control['timestamp'] ??
                      DateTime.now().millisecondsSinceEpoch,
                });
                _observeDataEnqueue(channel.send(RTCDataChannelMessage(text)),
                    'pong', utf8.encode(text).length);
              } catch (error) {
                _peerLog('link.exception',
                    error: error,
                    fields: {'phase': 'start', 'result': 'failed'});
              }
              return;
            }
            if (_isValidInput(control)) _executeInput(control);
          }
        } on FormatException catch (error) {
          _peerLog('link.data.invalid',
              error: error, fields: {'message_type': 'unknown'});
          // Malformed DTLS payloads are ignored; they never reach the injector.
        }
      };
    };
    peer.onConnectionState = (state) {
      _peerLog('link.pc.state', fields: {'pc_state': state.name});
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        markPeerConnected('pc_state');
      } else if (state ==
              RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        _peerLog('link.pc.grace', fields: {
          'result': 'scheduled',
          'timeout_ms': connectionGracePeriod.inMilliseconds
        });
        _connectionGraceTimer ??= Timer(connectionGracePeriod, () {
          _peerLog('link.pc.grace',
              fields: {'result': 'expired', 'origin': 'timeout'});
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

    await _peerStep(
        'set_remote',
        () => peer
            .setRemoteDescription(RTCSessionDescription(offerSdp, 'offer')));
    final capture = await _peerStep('capture_screen', _captureScreen);
    _peerLog('link.capture.tracks',
        fields: {'tracks': capture.getTracks().length});
    if (_closed) {
      capture.getTracks().forEach((track) => track.stop());
      await capture.dispose();
      throw StateError('Link host peer closed during capture');
    }
    _stream = capture;
    MediaStream? audioCapture = capture.getAudioTracks().isNotEmpty
        ? capture
        : await _peerStep('acquire_audio', _acquireAudioStream);
    if (audioCapture != null && audioCapture.getAudioTracks().isNotEmpty) {
      _audioStream = audioCapture;
      if (audioCapture != capture) {
        for (final track in audioCapture.getAudioTracks()) {
          await capture.addTrack(track, addToNative: false);
        }
      }
    }
    for (final track in capture.getVideoTracks()) {
      _videoSender = await peer.addTrack(track, capture);
    }
    if (_audioStream != null) {
      for (final track in _audioStream!.getAudioTracks()) {
        _audioSender = await peer.addTrack(track, capture);
      }
    }
    try {
      final transceivers = await peer.getTransceivers();
      for (final t in transceivers) {
        if (t.sender.track != null) {
          await t.setDirection(TransceiverDirection.SendOnly);
        } else {
          await t.setDirection(TransceiverDirection.Inactive);
        }
      }
    } catch (e) {
      _peerLog('link.exception',
          error: e, fields: {'phase': 'start', 'result': 'failed'});
    }
    final answer = await _peerStep('answer_create', peer.createAnswer);
    await _peerStep('set_local', () => peer.setLocalDescription(answer));

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
    await _peerStep(
        'set_remote',
        () => peer
            .setRemoteDescription(RTCSessionDescription(offerSdp, 'offer')));
    try {
      final transceivers = await peer.getTransceivers();
      for (final t in transceivers) {
        if (t.sender.track != null) {
          await t.setDirection(TransceiverDirection.SendOnly);
        } else {
          await t.setDirection(TransceiverDirection.Inactive);
        }
      }
    } catch (e) {
      _peerLog('link.exception',
          error: e, fields: {'phase': 'renegotiate_offer', 'result': 'failed'});
    }
    final answer = await _peerStep('answer_create', peer.createAnswer);
    await _peerStep('set_local', () => peer.setLocalDescription(answer));
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
    if (_closed || !policy.allows(input, allowControl: _allowControl)) {
      if (input['type'] == 'mouse_move') _mousePolicyBlocked++;
      if (input['type'] != 'mouse_move') {
        _peerLog('link.input.gate', fields: {
          'message_type': supportDebugMessageType(input['type']),
          'reason': 'policy',
          'result': 'blocked'
        });
      }
      return;
    }
    final type = input['type'];
    if (type != 'chat_message' && type != 'chat_sync' && type != 'chat_ack') {
      if (isRecorderReady != null && !isRecorderReady!()) {
        if (input['type'] == 'mouse_move') _mouseRecorderBlocked++;
        if (input['type'] != 'mouse_move') {
          _peerLog('link.input.gate', fields: {
            'message_type': supportDebugMessageType(input['type']),
            'reason': 'recorder_not_ready',
            'result': 'blocked'
          });
        }
        return; // Gated until durable first frame is acked (ULR-03)
      }
    }
    if (type != 'mouse_move') {
      _peerLog('link.input.dispatch', fields: {
        'message_type': supportDebugMessageType(type),
        'operation': 'execute',
        'result': 'begin'
      });
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
      final throttle = recordingConfig?.activityThrottle ?? const Duration(milliseconds: 500);
      final debounce = recordingConfig?.activityDebounce ?? const Duration(milliseconds: 200);
      if (_activitySnapshotTimer == null &&
          (_lastFrameCaptureAt == null ||
              now.difference(_lastFrameCaptureAt!) >= throttle)) {
        _activitySnapshotTimer = Timer(
          debounce,
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
          final control = _control;
          if (control == null) {
            _peerLog('link.data.outbound', fields: {
              'message_type': 'clipboard_data',
              'result': 'blocked',
            });
          } else {
            final encoded =
                jsonEncode({'type': 'clipboard_data', 'text': text});
            _observeDataEnqueue(control.send(RTCDataChannelMessage(encoded)),
                'clipboard_data', utf8.encode(encoded).length);
          }
        }).catchError((Object error) {
          _peerLog('link.clipboard.failed',
              error: error,
              fields: {'operation': 'clipboard_get', 'result': 'failed'});
        });
      } else if (type == 'block_input') {
        final blocked = input['blocked'] == true;
        injector.setInputBlocked(blocked);
        _sendControlJson({
          'type': 'block_input_ack',
          'blocked': blocked,
        });
      }
    } catch (error) {
      _peerLog('link.exception',
          error: error, fields: {'phase': 'execute_input', 'result': 'failed'});
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
    final type = supportDebugMessageType(payload['type']);
    if (_closed ||
        control == null ||
        control.state != RTCDataChannelState.RTCDataChannelOpen) {
      _peerLog('link.data.outbound',
          fields: {'message_type': type, 'result': 'blocked'});
      return false;
    }
    try {
      final text = jsonEncode(payload);
      _observeDataEnqueue(control.send(RTCDataChannelMessage(text)),
          supportDebugMessageType(payload['type']), utf8.encode(text).length);

      return true;
    } catch (error) {
      _peerLog('link.exception',
          error: error,
          fields: {'phase': 'send_control_json', 'result': 'failed'});
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
        _peerLog('link.exception',
            error: e,
            fields: {'phase': 'handle_video_quality', 'result': 'failed'});
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
        Process.run('systemctl', ['reboot']).catchError((Object error) {
          _linkLog('link.async.failed', error: error);
          return Process.run('shutdown', ['-r', 'now']);
        });
      } else if (!kIsWeb && Platform.isMacOS) {
        Process.run('shutdown', ['-r', 'now']);
      }
    } catch (e) {
      _peerLog('link.exception',
          error: e,
          fields: {'phase': 'handle_remote_reboot', 'result': 'failed'});
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
    } catch (error) {
      _peerLog('link.exception',
          error: error,
          fields: {'phase': 'handle_file_chunk', 'result': 'failed'});
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
        } catch (error) {
          _peerLog('link.exception',
              error: error,
              fields: {'phase': 'handle_file_end', 'result': 'failed'});
        }
      }
      _sendControlJson({
        'type': 'file_ack',
        'transfer_id': transferId,
        'ok': true,
      });
    } catch (error) {
      _peerLog('link.exception',
          error: error,
          fields: {'phase': 'handle_file_end', 'result': 'failed'});
      if (targetPath != null) {
        try {
          final partFile = File('$targetPath.part');
          if (await partFile.exists()) await partFile.delete();
        } catch (error) {
          _peerLog('link.exception',
              error: error,
              fields: {'phase': 'handle_file_end', 'result': 'failed'});
        }
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
        .catchError((Object error) {
          _linkLog('link.capture.failed', error: error, fields: {
            'phase': 'sources',
            'reason': 'host_screen_capture_unavailable'
          });
          throw const LinkHostReadinessException(
              'host_screen_capture_unavailable');
        });
    if (sources.isEmpty) {
      throw const LinkHostReadinessException('host_screen_capture_unavailable');
    }
    _peerLog('link.capture.sources', fields: {'count': sources.length});
    final source = sources.first;
    _selectedScreenId = source.id;
    _screenRect = InputInjector.instance.getMonitorRectForSource(source.id);
    InputInjector.instance.setActiveMonitorRect(_screenRect);
    _peerLog('link.capture.monitor',
        fields: {'width': _screenRect?.width, 'height': _screenRect?.height});
    try {
      return await _openDisplayStream(source.id);
    } catch (error) {
      _peerLog('link.exception',
          error: error,
          fields: {'phase': 'capture_screen', 'result': 'failed'});
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
    _flushMouseSummary();
    _peerLog('link.peer.close', fields: {'result': 'begin'});
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
    InputInjector.instance.setDesktopScope('interactive');
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
