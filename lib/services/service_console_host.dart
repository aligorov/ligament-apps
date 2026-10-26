import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../api/client.dart';
import 'support_service.dart';
import 'debug_log_service.dart';

void _consoleLog(String event,
        {Object? error, Map<String, Object?> fields = const {}}) =>
    DebugLogService.instance.record(event, error: error, fields: {
      ...fields,
      if (fields.containsKey('reason'))
        'reason': DebugLogService.protocolLabel(fields['reason']),
    });

const _serviceConsoleChannel = MethodChannel('ligament/service_console');

Future<void> updateServiceConsoleInputLease(int remainingMilliseconds) =>
    _serviceConsoleChannel.invokeMethod<void>('lease', remainingMilliseconds);
final _consoleUuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  caseSensitive: false,
);
// ConsoleHostProcess::NewPipeName uses 16 random bytes encoded as 32 hex
// characters. Keep UUID names compatible with earlier workers and tests.
final _consolePipeId = RegExp(
  r'^(?:[0-9a-f]{32}|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$',
  caseSensitive: false,
);

/// A pipe name is an address, never a credential. Native code verifies that
/// this pipe belongs to the LocalSystem service before reading its contents.
String? serviceConsolePipeFromArgs(List<String> args) {
  final flags =
      args.where((arg) => arg.startsWith('--service-console')).toList();
  if (flags.isEmpty) return null;
  const option = '--service-console=';
  const prefix = r'\\.\pipe\LigamentConsole-';
  if (flags.length != 1 || !flags.single.startsWith(option)) {
    throw const FormatException('Invalid service console option');
  }
  final pipe = flags.single.substring(option.length);
  if (!pipe.startsWith(prefix) ||
      !_consolePipeId.hasMatch(pipe.substring(prefix.length))) {
    throw const FormatException('Invalid service console pipe');
  }
  return pipe;
}

class ServiceConsoleBootstrap {
  const ServiceConsoleBootstrap({
    required this.sessionId,
    required this.serverUrl,
    required this.hostToken,
  });

  final String sessionId;
  final Uri serverUrl;
  final String hostToken;

  factory ServiceConsoleBootstrap.fromNative(Object? value) {
    final decoded = value is String ? jsonDecode(value) : value;
    if (decoded is! Map) {
      throw const FormatException('Invalid service bootstrap');
    }
    final session = decoded['session_id'];
    final server = decoded['server_url'];
    final token = decoded['host_token'];
    if (session is! String ||
        !_consoleUuid.hasMatch(session) ||
        server is! String ||
        token is! String ||
        token.length < 32 ||
        token.length > 4096 ||
        token.contains(RegExp(r'\s'))) {
      throw const FormatException('Invalid service bootstrap');
    }
    final uri = Uri.tryParse(server);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const FormatException('Invalid service server URL');
    }
    return ServiceConsoleBootstrap(
      sessionId: session,
      serverUrl: uri,
      hostToken: token,
    );
  }

  Uri get websocketUrl => serverUrl.replace(
        scheme: 'wss',
        path: '${serverUrl.path.replaceFirst(RegExp(r'/+$'), '')}'
            '/api/v1/endpoint/console/$sessionId/ws',
      );
}

/// A monotonic deadline cannot be extended by changing the Windows clock.
/// Only an authenticated server lease frame may extend this deadline.
class ServiceConsoleLease {
  ServiceConsoleLease({int Function()? elapsedMilliseconds}) {
    final watch = Stopwatch()..start();
    _now = elapsedMilliseconds ?? (() => watch.elapsedMilliseconds);
  }

  static const maxLeaseMilliseconds = 60000;
  static const safetyMarginMilliseconds = 250;
  late final int Function() _now;
  int? _deadline;

  void update(int remainingMilliseconds) {
    if (remainingMilliseconds <= safetyMarginMilliseconds ||
        remainingMilliseconds > maxLeaseMilliseconds) {
      throw const FormatException('Invalid service lease');
    }
    _deadline = _now() + remainingMilliseconds - safetyMarginMilliseconds;
  }

  int get remainingMilliseconds =>
      ((_deadline ?? _now()) - _now()).clamp(0, maxLeaseMilliseconds);

  bool get isLive => _deadline != null && remainingMilliseconds > 0;
}

/// The controller is independent of plugins so protocol, cancellation and
/// authorization-expiry behavior can be verified without a Windows desktop.
abstract interface class ServiceConsoleCapture {
  void setFailureHandler(void Function() handler);
  Future<void> start({
    required String sessionId,
    required String accessMode,
    required ApiClient api,
  });
  Future<void> handleSignal(Map<String, dynamic> signal);
  Future<void> stop();
}

class ServiceConsoleController {
  ServiceConsoleController({
    required this.sessionId,
    required this.capture,
    required this.send,
    required this.onStopped,
    this.onLease,
    this.serverUrl,
    this.hostToken,
    ServiceConsoleLease? lease,
    DebugLogService? debugLog,
    Duration readyTimeout = const Duration(seconds: 15),
  })  : lease = lease ?? ServiceConsoleLease(),
        _debugLog = debugLog ?? DebugLogService.instance {
    _controllerLog('console.controller.start', fields: {
      'session_id': sessionId,
      'timeout_ms': readyTimeout.inMilliseconds
    });
    capture.setFailureHandler(() {
      unawaited(stop('capture_unavailable'));
    });
    _readyTimer = Timer(readyTimeout, () {
      _controllerLog('console.timer.expired',
          fields: {'phase': 'ready', 'reason': 'host_ready_timeout'});
      unawaited(stop('host_ready_timeout'));
    });
    _leaseTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (_ready && !this.lease.isLive) {
        _controllerLog('console.timer.expired',
            fields: {'phase': 'lease', 'reason': 'lease_expired'});
        unawaited(stop('lease_expired'));
      }
    });
  }

  final String sessionId;
  final ServiceConsoleCapture capture;
  final void Function(Map<String, dynamic>) send;
  final Future<void> Function(String reason) onStopped;
  final Future<void> Function(int remainingMilliseconds)? onLease;
  final Uri? serverUrl;
  final String? hostToken;
  final ServiceConsoleLease lease;
  final DebugLogService _debugLog;
  Timer? _readyTimer;
  Timer? _leaseTimer;
  bool _ready = false;
  bool _stopped = false;
  Future<void>? _stopping;
  Future<void> _signals = Future<void>.value();

  void _controllerLog(String event,
      {Object? error, Map<String, Object?> fields = const {}}) {
    _debugLog.record(event, error: error, fields: {
      'session_id': sessionId,
      'state': _stopped
          ? 'stopped'
          : _ready
              ? 'ready'
              : 'starting',
      'timeout_ms': lease.remainingMilliseconds,
      ...fields,
      if (fields.containsKey('reason'))
        'reason': DebugLogService.protocolLabel(fields['reason']),
    });
  }

  bool get isStopped => _stopped;

  void receive(Object? frame) {
    if (_stopped) return;
    try {
      if (frame is! String || frame.length > 262144) {
        throw const FormatException('Invalid service frame');
      }
      final decoded = jsonDecode(frame);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Invalid service frame');
      }
      final type = decoded['type'];
      _controllerLog('console.message.inbound', fields: {
        'message_type': supportDebugMessageType(type),
        'bytes': utf8.encode(frame).length
      });
      // Lease/end frames must not wait behind media acquisition or SDP work.
      if (type == 'console_end') {
        unawaited(stop('server_ended', report: false));
      } else if (type == 'lease') {
        if (!_ready) throw const FormatException('Lease before ready');
        _updateLease(decoded['remaining_ms']);
      } else if (type == 'console_ready') {
        if (_ready || decoded['session_id'] != sessionId) {
          throw const FormatException('Invalid service ready scope');
        }
        final mode = decoded['access_mode'];
        if (mode != 'view_only' && mode != 'full_control') {
          throw const FormatException('Invalid service access mode');
        }
        _updateLease(decoded['lease_remaining_ms']);
        final ice = parseIceServersConfig(decoded);
        _ready = true;
        _controllerLog('console.ready',
            fields: {'ice_servers': ice.length, 'result': 'validated'});
        _readyTimer?.cancel();
        final base = serverUrl != null
            ? serverUrl.toString().replaceAll(RegExp(r'/+$'), '')
            : '';
        final api =
            _ServiceConsoleApi(this, ice, baseUrl: base, token: hostToken);
        _enqueue(() async {
          if (_stopped) return;
          await capture.start(
            sessionId: sessionId,
            accessMode: mode as String,
            api: api,
          );
          if (_stopped) await capture.stop();
        });
      } else if (type == 'signal') {
        final signal = decoded['signal'];
        if (!_ready || signal is! Map<String, dynamic>) {
          throw const FormatException('Invalid service signal');
        }
        _enqueue(() => capture.handleSignal(signal));
      } else if (type != 'pong') {
        throw const FormatException('Unknown service frame');
      }
    } catch (error) {
      _controllerLog('console.exception',
          error: error, fields: {'phase': 'receive', 'result': 'failed'});
      unawaited(stop('invalid_host_protocol'));
    }
  }

  void _updateLease(Object? raw) {
    if (raw is! int) throw const FormatException('Invalid service lease');
    lease.update(raw);
    _controllerLog('console.lease.updated', fields: {
      'timeout_ms': lease.remainingMilliseconds,
      'result': 'validated'
    });
    final update = onLease;
    if (update != null) {
      unawaited(update(lease.remainingMilliseconds).catchError((Object error) {
        _controllerLog('console.lease.input_failed', error: error);
        unawaited(stop('input_unavailable'));
      }));
    }
  }

  void _enqueue(Future<void> Function() action) {
    _signals = _signals.then((_) async {
      if (!_stopped) await action();
    }).catchError((Object error) {
      _controllerLog('console.capture.failed', error: error);
      unawaited(stop('capture_unavailable'));
    });
  }

  void sendSignal(String targetSession, Map<String, dynamic> signal) {
    if (_stopped || !_ready || !lease.isLive || targetSession != sessionId) {
      _controllerLog('console.signal.blocked', fields: {
        'reason': 'session_not_live',
        'message_type': supportDebugMessageType(signal['type'])
      });
      throw StateError('service_session_not_live');
    }
    // The service token authorizes media signaling only, never files or chat.
    final type = signal['type']?.toString() ?? '';
    if (type.startsWith('file_') ||
        type.startsWith('clipboard_') ||
        type == 'chat_message' ||
        type == 'input_control') {
      _controllerLog('console.signal.blocked', fields: {
        'reason': 'signal_not_allowed',
        'message_type': supportDebugMessageType(signal['type'])
      });
      throw StateError('service_signal_not_allowed');
    }
    _controllerLog('console.signal.outbound', fields: {
      'message_type': supportDebugMessageType(signal['type']),
      'result': 'begin'
    });
    send({'type': 'signal', 'signal': signal});
    _controllerLog('console.signal.outbound', fields: {
      'message_type': supportDebugMessageType(signal['type']),
      'result': 'queued'
    });
  }

  Future<void> stop(String reason, {bool report = true}) {
    final stopping = _stopping;
    if (stopping != null) return stopping;
    _controllerLog('console.stop',
        fields: {'reason': reason, 'result': 'begin'});
    _stopped = true;
    _readyTimer?.cancel();
    _leaseTimer?.cancel();
    if (report) {
      try {
        send({'type': 'console_error', 'reason': reason});
        _controllerLog('console.message.outbound',
            fields: {'message_type': 'console_error', 'result': 'queued'});
      } catch (error) {
        _controllerLog('console.exception',
            error: error, fields: {'phase': 'stop', 'result': 'failed'});
      }
    }
    return _stopping = _finishStop(reason);
  }

  Future<void> _finishStop(String reason) async {
    try {
      await _serviceConsoleChannel.invokeMethod<void>('releaseInput');
    } catch (error) {
      _controllerLog('console.exception',
          error: error, fields: {'phase': 'finish_stop', 'result': 'failed'});
    }
    try {
      await capture.stop().timeout(const Duration(seconds: 2));
      _controllerLog('console.stop',
          fields: {'reason': reason, 'result': 'capture_stopped'});
    } catch (error) {
      _controllerLog('console.stop', error: error, fields: {
        'reason': reason,
        'phase': 'capture_stop',
        'result': error is TimeoutException ? 'timeout' : 'failed',
      });
    }
    await onStopped(reason);
  }
}

class _ServiceConsoleApi extends ApiClient {
  _ServiceConsoleApi(
    this.controller,
    this.iceServers, {
    super.baseUrl = '',
    super.token,
  });

  final ServiceConsoleController controller;
  final List<Map<String, dynamic>> iceServers;

  @override
  Future<List<Map<String, dynamic>>> getIceServers() async => iceServers;

  @override
  Future<Map<String, dynamic>> getConfig() async => {'ice_servers': iceServers};

  @override
  Future<List<Map<String, dynamic>>> getSupportMessages(
          String sessionId) async =>
      [];

  @override
  Future<Map<String, dynamic>?> getCurrentSupportSession() async =>
      !controller.isStopped && controller.lease.isLive
          ? {'id': controller.sessionId, 'status': 'active'}
          : null;

  @override
  Future<void> sendSupportSignal({
    required String sessionId,
    required Map<String, dynamic> signal,
  }) async =>
      controller.sendSignal(sessionId, signal);
}

Future<void> sendServiceConsoleInput(Map<String, dynamic> input) async {
  final accepted =
      await _serviceConsoleChannel.invokeMethod<bool>('input', input);
  if (accepted != true) throw StateError('Remote input rejected');
}

class _WebRtcServiceCapture implements ServiceConsoleCapture {
  _WebRtcServiceCapture() {
    _service = SupportService(
      serviceHost: true,
      serviceInput: sendServiceConsoleInput,
      serviceReleaseInput: () =>
          _serviceConsoleChannel.invokeMethod<void>('releaseInput'),
    );
    _service.addListener(() {
      if (_service.state == SupportSessionState.ended) _onFailure?.call();
    });
  }

  late final SupportService _service;
  void Function()? _onFailure;

  @override
  void setFailureHandler(void Function() handler) => _onFailure = handler;

  @override
  Future<void> start({
    required String sessionId,
    required String accessMode,
    required ApiClient api,
  }) async {
    _service.setAuthorizing(
      sessionId: sessionId,
      accessMode: accessMode,
      owner: true,
      api: api,
    );
    await _service.startScreenSharing(
      sessionId: sessionId,
      api: api,
      accessMode: accessMode,
    );
  }

  @override
  Future<void> handleSignal(Map<String, dynamic> signal) =>
      _service.handleRemoteSignal(signal);

  @override
  Future<void> stop() => _service.stopScreenSharing();
}

/// Called before the ordinary app initializes. A failed bootstrap never
/// falls back to GUI login. A disconnected worker exits; the service owns its
/// lifetime and requests a fresh, session-bound authorization for a new one.
Future<void> runServiceConsoleHost(String pipe) async {
  final watch = Stopwatch()..start();
  var phase = 'bootstrap';
  _consoleLog('console.bootstrap.begin',
      fields: {'operation': 'bootstrap', 'timeout_ms': 10000});
  try {
    final raw = await _serviceConsoleChannel
        .invokeMethod<Object?>('bootstrap', pipe)
        .timeout(const Duration(seconds: 10));
    _consoleLog('console.bootstrap.received', fields: {
      'operation': 'bootstrap',
      'bytes': raw is String ? utf8.encode(raw).length : 0,
      'duration_ms': watch.elapsedMilliseconds
    });
    final bootstrap = ServiceConsoleBootstrap.fromNative(raw);
    _consoleLog('console.bootstrap.validated', fields: {
      'session_id': bootstrap.sessionId,
      'server': bootstrap.serverUrl.host,
      'result': 'validated'
    });
    phase = 'ws_connect';
    watch.reset();
    final socket = await WebSocket.connect(
      bootstrap.websocketUrl.toString(),
      headers: {'Authorization': 'Bearer ${bootstrap.hostToken}'},
    ).timeout(const Duration(seconds: 10));
    _consoleLog('console.ws.ready', fields: {
      'session_id': bootstrap.sessionId,
      'server': bootstrap.serverUrl.host,
      'duration_ms': watch.elapsedMilliseconds
    });
    phase = 'session';
    socket.pingInterval = const Duration(seconds: 10);
    final done = Completer<void>();
    String stopReason = '';
    final host = ServiceConsoleController(
      sessionId: bootstrap.sessionId,
      capture: _WebRtcServiceCapture(),
      send: (frame) {
        final text = jsonEncode(frame);
        try {
          socket.add(text);
          _consoleLog('console.ws.outbound', fields: {
            'session_id': bootstrap.sessionId,
            'message_type': supportDebugMessageType(frame['type']),
            'bytes': utf8.encode(text).length,
            'result': 'queued'
          });
        } catch (error) {
          _consoleLog('console.ws.outbound', error: error, fields: {
            'message_type': supportDebugMessageType(frame['type']),
            'result': 'failed'
          });
          rethrow;
        }
      },
      onLease: updateServiceConsoleInputLease,
      serverUrl: bootstrap.serverUrl,
      hostToken: bootstrap.hostToken,
      onStopped: (reason) async {
        stopReason = reason;
        _consoleLog('console.worker.stopped',
            fields: {'session_id': bootstrap.sessionId, 'reason': reason});

        unawaited(socket.close());
        if (!done.isCompleted) done.complete();
      },
    );
    socket.listen(
      host.receive,
      onError: (Object error) {
        _consoleLog('console.ws.error',
            error: error, fields: {'origin': 'ws_state'});
        unawaited(host.stop('signaling_lost', report: false));
      },
      onDone: () {
        _consoleLog('console.ws.done',
            fields: {'origin': 'ws_state', 'code': socket.closeCode});
        unawaited(host.stop('signaling_closed', report: false));
      },
      cancelOnError: true,
    );
    await done.future;
    // If stopped cleanly by server command, exit 0 so service breaks from loop.
    // If stopped abnormally (desktop switch, error, crash), exit 1 so service restarts worker.
    exit(stopReason == 'server_ended' ? 0 : 1);
  } catch (error) {
    _consoleLog('console.worker.failed',
        error: error,
        fields: {'phase': phase, 'duration_ms': watch.elapsedMilliseconds});
    rethrow;
  }
}
