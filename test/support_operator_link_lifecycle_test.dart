import 'dart:async';
import 'dart:io';

// ignore: depend_on_referenced_packages
import 'package:file/memory.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ligament_authenticator/api/client.dart';
import 'package:ligament_authenticator/screens/support_operator_screen.dart';
import 'package:ligament_authenticator/services/auth_state.dart';
import 'package:ligament_authenticator/services/debug_log_service.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _sessionId = '10000000-0000-4000-8000-000000000001';
const _secondSessionId = '10000000-0000-4000-8000-000000000002';
const _params = {
  'encodings': [],
  'headerExtensions': [],
  'codecs': [],
  'rtcp': {'cname': 'test', 'reducedSize': true},
};

Map<String, dynamic> _track(String kind) => {
      'id': '$kind-track',
      'label': kind,
      'kind': kind,
      'enabled': true,
    };

Map<String, dynamic> _receiver(String kind) => {
      'receiverId': '$kind-receiver',
      'track': _track(kind),
      'rtpParameters': _params,
    };

Map<String, dynamic> _signal(String type, Map<String, dynamic> payload) => {
      'type': type,
      'payload': {'type': type, ...payload},
    };

class _DirectoryProvider extends PathProviderPlatform {
  _DirectoryProvider(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

// Retain the real logger and its sanitization without fsync latency or real
// file futures escaping the widget's fake-async zone. Only test logs are mapped.
final class _LogFiles extends IOOverrides {
  _LogFiles(this.root) {
    files.directory('$root/logs').createSync(recursive: true);
  }
  final String root;
  final files = MemoryFileSystem();

  @override
  File createFile(String path) =>
      path.startsWith('$root/') ? files.file(path) : super.createFile(path);
}

class _PendingCandidate {
  _PendingCandidate(this.sessionId, this.signal);
  final String sessionId;
  final Map<String, dynamic> signal;
  final done = Completer<void>();
}

class _Api extends ApiClient {
  _Api() : super(baseUrl: 'https://operator.test');
  final request = Completer<Map<String, dynamic>>();
  final candidates = <_PendingCandidate>[];
  final closes = <String>[];
  final otherSignals = <Map<String, dynamic>>[];
  final inbound = <Map<String, dynamic>>[];
  final polledSessions = <String>[];
  final heldPolls = <Completer<Map<String, dynamic>>>[];
  Completer<void>? closeResult;
  Completer<Map<String, dynamic>>? pollResult;
  int polls = 0;
  int heartbeats = 0;
  int legacyEnds = 0;
  int requests = 0;
  int activeCandidates = 0;
  int maxActiveCandidates = 0;
  bool holdCandidates = true;

  @override
  Future<List<Map<String, dynamic>>> getLinkIceServers() async => [];

  @override
  Future<List<Map<String, dynamic>>> getSupportMessages(String id) async => [];

  @override
  Future<Map<String, dynamic>> requestLinkSession({
    required String agentId,
    String accessMode = 'view',
    String? clientSdp,
    String? resolution,
    String? actionId,
    String? sessionKind,
    String? stepUpToken,
  }) {
    requests++;
    return requests == 1
        ? request.future
        : Future.value({'session_id': _secondSessionId});
  }

  @override
  Future<Map<String, dynamic>> startSOSSession({
    required String requestId,
    required String sessionId,
    required String clientSdp,
    String accessMode = 'control',
  }) {
    requests++;
    return request.future;
  }

  @override
  Future<void> sendLinkSessionSignal({
    required String sessionId,
    required Map<String, dynamic> signal,
  }) async {
    if (signal['type'] != 'candidate') {
      otherSignals.add(signal);
      return;
    }
    final pending = _PendingCandidate(sessionId, signal);
    candidates.add(pending);
    activeCandidates++;
    if (activeCandidates > maxActiveCandidates) {
      maxActiveCandidates = activeCandidates;
    }
    try {
      if (holdCandidates) await pending.done.future;
    } finally {
      activeCandidates--;
    }
  }

  @override
  Future<Map<String, dynamic>> getLinkSessionSignals(
      {required String sessionId, int after = 0}) async {
    polls++;
    polledSessions.add(sessionId);
    if (pollResult != null) {
      heldPolls.add(pollResult!);
      return pollResult!.future;
    }
    final signals = List<Map<String, dynamic>>.from(inbound);
    inbound.clear();
    return {'next_cursor': polls, 'signals': signals};
  }

  @override
  Future<void> heartbeatLinkSession(String id) async => heartbeats++;

  @override
  Future<void> closeLinkSession(String id) {
    closes.add(id);
    return closeResult?.future ?? Future<void>.value();
  }

  @override
  Future<void> endSupportSession({required String sessionId}) async =>
      legacyEnds++;

  @override
  Future<void> endSupportSessionAsOperator({required String sessionId}) async =>
      legacyEnds++;
}

// Exercise the screen's production handlers through flutter_webrtc's actual
// event decoding, without exposing State internals or copying its algorithms.
class _Native {
  final calls = <MethodCall>[];
  final channels = <String>[];
  final errors = <String>{};
  Completer<void>? localDescriptionGate;
  int peers = 0;
  String get peerId => 'peer-$peers';
  String get peerEvents => 'FlutterWebRTC/peerConnectionEvent$peerId';
  String get dataEvents => 'FlutterWebRTC/dataChannelEvent${peerId}dc';
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  void eventChannel(String name) {
    channels.add(name);
    messenger.setMockMethodCallHandler(MethodChannel(name), (_) async => null);
  }

  void install() {
    eventChannel('FlutterWebRTC.Event');
    eventChannel('xyz.luan/audioplayers.global/events');
    messenger.setMockMethodCallHandler(
        const MethodChannel('xyz.luan/audioplayers'), (call) async {
      if (call.method == 'create') {
        final id = (call.arguments as Map)['playerId'];
        eventChannel('xyz.luan/audioplayers/events/$id');
      }
      return null;
    });
    messenger.setMockMethodCallHandler(
        const MethodChannel('xyz.luan/audioplayers.global'), (_) async => null);
    messenger.setMockMethodCallHandler(
        const MethodChannel('FlutterWebRTC.Method'), (call) async {
      calls.add(call);
      if (errors.contains(call.method)) {
        throw PlatformException(
            code: 'test_failure', message: 'test-only failure');
      }
      switch (call.method) {
        case 'createVideoRenderer':
          eventChannel('FlutterWebRTC/Texture7');
          return {'textureId': 7};
        case 'createPeerConnection':
          peers++;
          eventChannel(peerEvents);
          return {'peerConnectionId': peerId};
        case 'addTransceiver':
          final kind = (call.arguments as Map)['mediaType'] as String;
          return {
            'direction': 'recvonly',
            'mid': '0',
            'transceiverId': kind,
            'sender': {
              'senderId': kind,
              'track': {},
              'rtpParameters': _params,
              'ownsTrack': false
            },
            'receiver': _receiver(kind),
          };
        case 'createDataChannel':
          eventChannel(dataEvents);
          return {'id': 1, 'flutterId': 'dc'};
        case 'createOffer':
          return {'sdp': 'v=0\r\n', 'type': 'offer'};
        case 'setLocalDescription':
          await localDescriptionGate?.future;
          return null;
        case 'getStats':
          return {'stats': []};
        default:
          return null;
      }
    });
    messenger.setMockMethodCallHandler(
        const MethodChannel('window_manager'),
        (call) async => call.method == 'getBounds'
            ? {'x': 0.0, 'y': 0.0, 'width': 440.0, 'height': 720.0}
            : null);
  }

  Future<void> emit(String channel, Map<String, dynamic> event) async {
    final done = Completer<void>();
    // ignore: deprecated_member_use
    messenger.handlePlatformMessage(
        channel,
        const StandardMethodCodec().encodeSuccessEnvelope(event),
        (_) => done.complete());
    await done.future;
  }

  Future<void> candidate(int index, {String? channel}) =>
      emit(channel ?? peerEvents, {
        'event': 'onCandidate',
        'candidate': {
          'candidate': 'candidate-$index',
          'sdpMid': '0',
          'sdpMLineIndex': 0
        },
      });

  Future<void> pc(String state) =>
      emit(peerEvents, {'event': 'peerConnectionState', 'state': state});

  Future<void> dataState(String state) => emit(dataEvents, {
        'event': 'dataChannelStateChanged',
        'id': 1,
        'state': state,
      });

  Future<void> track(String kind, {bool includeAudio = false}) =>
      emit(peerEvents, {
        'event': 'onTrack',
        'track': _track(kind),
        'receiver': _receiver(kind),
        'streams': [
          {
            'streamId': 'remote',
            'ownerTag': peerId,
            'audioTracks':
                includeAudio || kind == 'audio' ? [_track('audio')] : [],
            'videoTracks': kind == 'video' ? [_track('video')] : [],
          }
        ],
      });

  int count(String method) =>
      calls.where((call) => call.method == method).length;

  void uninstall() {
    for (final name in [
      'FlutterWebRTC.Method',
      'window_manager',
      ...channels
    ]) {
      messenger.setMockMethodCallHandler(MethodChannel(name), null);
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Api api;
  late _Native native;
  late AuthState auth;
  late Directory directory;
  late PathProviderPlatform originalDirectoryProvider;
  late IOOverrides? originalIoOverrides;
  final logs = DebugLogService.instance;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('operator-link-tests-');
    originalDirectoryProvider = PathProviderPlatform.instance;
    originalIoOverrides = IOOverrides.current;
    IOOverrides.global = _LogFiles(directory.path);
    PathProviderPlatform.instance = _DirectoryProvider(directory.path);
    await logs.setEnabled(true);
    await logs.flush();
  });

  tearDownAll(() async {
    await logs.setEnabled(false);
    await logs.flush();
    PathProviderPlatform.instance = originalDirectoryProvider;
    IOOverrides.global = originalIoOverrides;
    await directory.delete(recursive: true);
  });

  setUp(() async {
    await logs.flush();
    await File(logs.path!).writeAsString('');
  });

  tearDown(() async {
    native.uninstall();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
        const MethodChannel('xyz.luan/audioplayers'), null);
    messenger.setMockMethodCallHandler(
        const MethodChannel('xyz.luan/audioplayers.global'), null);
    await logs.flush();
  });

  Future<void> pumpSteps(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      // EventChannel cancellation also uses real-zone futures. Let those
      // complete without advancing the fake poll/heartbeat deadlines.
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
    }
  }

  Future<void> mount(WidgetTester tester,
      {Map<String, dynamic> data = const {}}) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(ChangeNotifierProvider<AuthState>.value(
      value: auth,
      child: MaterialApp(
          home: SupportOperatorScreen(
        sessionId: 'link_synthetic-agent',
        isLink: true,
        ownerMode: true,
        linkAgentId: 'agent',
        sessionData: data,
      )),
    ));
    await pumpSteps(tester);
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 600));
    await pumpSteps(tester);
    expect(tester.takeException(), isNull);
  }

  Future<void> end(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.call_end));
    // Only finish the dialog animation: the waiting screen has an infinite
    // progress animation and pumpAndSettle would advance its 120s deadline.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.descendant(
        of: find.byType(AlertDialog), matching: find.byType(ElevatedButton)));
    await pumpSteps(tester);
  }

  Future<void> flushLogs(WidgetTester tester) async {
    // File I/O completes on the real event loop, but record() continuations
    // belong to the widget test's fake zone. Drive both until the queue drains.
    // End on a real-zone future so tearDown/next setUp can also await flush().
    await tester.runAsync(() async => logs.record('test.drain'));
    var flushed = false;
    unawaited(logs.flush().then((_) => flushed = true));
    final watch = Stopwatch()..start();
    while (!flushed && watch.elapsed < const Duration(seconds: 5)) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
    }
    expect(flushed, isTrue, reason: 'Diagnostic writes did not drain');
  }

  Future<String> logContent(WidgetTester tester) async {
    await flushLogs(tester);
    return (await tester.runAsync(() => File(logs.path!).readAsString()))!;
  }

  void lifecycleTest(String description, WidgetTesterCallback body) {
    testWidgets(description, (tester) async {
      // Completers must be created in this fake-async zone, not setUp's real
      // zone; otherwise pump() cannot advance request completion callbacks.
      api = _Api();
      native = _Native()..install();
      auth = AuthState()..api = api;
      try {
        await body(tester);
      } finally {
        // Always cancel screen timers and release every deliberately held
        // request, including on an assertion failure before unmount().
        await tester.pumpWidget(const SizedBox.shrink());
        api.holdCandidates = false;
        if (!api.request.isCompleted) {
          api.request.complete({'session_id': _sessionId});
        }
        for (final candidate in api.candidates) {
          if (!candidate.done.isCompleted) candidate.done.complete();
        }
        for (final poll in api.heldPolls) {
          if (!poll.isCompleted) poll.complete({'signals': []});
        }
        if (api.closeResult != null && !api.closeResult!.isCompleted) {
          api.closeResult!.complete();
        }
        if (native.localDescriptionGate != null &&
            !native.localDescriptionGate!.isCompleted) {
          native.localDescriptionGate!.complete();
        }
        await tester.pump(const Duration(milliseconds: 600));
        await pumpSteps(tester);
        await flushLogs(tester);
      }
    });
  }

  lifecycleTest(
      '48 queued candidates do not block poll or heartbeat; late ICE stays ordered and bounded',
      (tester) async {
    await mount(tester);
    expect(api.requests, 1);
    for (var i = 0; i < 48; i++) {
      await native.candidate(i);
    }
    api.request.complete({'session_id': _sessionId});
    await pumpSteps(tester);
    expect(api.polls, greaterThan(0));
    expect(api.candidates, hasLength(1));
    await native.candidate(48);
    await tester.pump(const Duration(seconds: 20));
    expect(api.heartbeats, 1);
    for (var i = 0; i < 49; i++) {
      expect(
          api.candidates[i].signal['candidate']['candidate'], 'candidate-$i');
      expect(api.candidates[i].sessionId, _sessionId);
      api.candidates[i].done.complete();
      await pumpSteps(tester);
    }
    expect(api.candidates, hasLength(49));
    expect(api.maxActiveCandidates, 1);
    await unmount(tester);
    expect(api.closes, [_sessionId]);
  });

  lifecycleTest(
      'host Recorder stop wins over closed DTLS/disconnected ICE and late 409',
      (tester) async {
    await mount(tester);
    for (var i = 0; i < 48; i++) {
      await native.candidate(i);
    }
    api.request.complete({'session_id': _sessionId});
    await pumpSteps(tester);
    api.inbound
        .add(_signal('session_answer', {'accepted': true, 'sdp': 'answer'}));
    await tester.pump(const Duration(milliseconds: 500));
    await native.pc('connected');
    api.pollResult = Completer<Map<String, dynamic>>();
    await native.dataState('closed');
    await native.pc('disconnected');
    await pumpSteps(tester);
    api.pollResult!.complete({
      'next_cursor': 20,
      'signals': [
        _signal('candidate', {
          'candidate': {
            'candidate': 'remote',
            'sdpMid': '0',
            'sdpMLineIndex': 0
          }
        }),
        _signal('session_terminate', {'reason': 'recorder_queue_overflow'}),
      ]
    });
    await pumpSteps(tester);
    expect(find.textContaining('Recorder'), findsOneWidget);
    expect(native.count('addCandidate'), 0);
    api.candidates.single.done.completeError(ApiException(409, 'ended'));
    await tester.pump(const Duration(seconds: 3));
    await pumpSteps(tester);
    expect(native.count('createOffer'), 1);
    expect(native.count('restartIce'), 0);
    expect(api.otherSignals.where((signal) => signal['type'] == 'ice_restart'),
        isEmpty);
    expect(api.candidates, hasLength(1));
    expect(api.closes, [_sessionId]);
    final content = await logContent(tester);
    expect(content, contains('reason=recorder_queue_overflow'));
    expect(content, contains('event=operator.candidate.local'));
    expect(content, contains('http_status=409'));
    await unmount(tester);
    expect(api.closes, [_sessionId]);
  });

  lifecycleTest('terminal candidate rejection blocks late ICE until host stop',
      (tester) async {
    api.request.complete({'session_id': _sessionId});
    await mount(tester);
    final poll = Completer<Map<String, dynamic>>();
    api.pollResult = poll;
    await tester.pump(const Duration(milliseconds: 500));
    await native.candidate(0);
    await native.candidate(1);
    api.candidates.single.done.completeError(ApiException(409, 'ended'));
    await pumpSteps(tester);
    await native.candidate(2);
    await pumpSteps(tester);
    expect(api.candidates, hasLength(1));
    expect(api.closes, isEmpty);
    poll.complete({
      'signals': [
        _signal('session_terminate', {'reason': 'recorder_queue_overflow'}),
      ]
    });
    await pumpSteps(tester);
    expect(find.textContaining('Recorder'), findsOneWidget);
    await unmount(tester);
    expect(api.closes, [_sessionId]);
  });

  lifecycleTest(
      'retry isolates pending candidate drains and polls from the old attempt',
      (tester) async {
    await mount(tester);
    await native.candidate(0);
    await native.candidate(1);
    api.request.complete({'session_id': _sessionId});
    await pumpSteps(tester);
    await native.track('video');
    await pumpSteps(tester);
    final oldPoll = Completer<Map<String, dynamic>>();
    api.pollResult = oldPoll;
    await tester.pump(const Duration(seconds: 15));
    final newPoll = Completer<Map<String, dynamic>>();
    api.pollResult = newPoll;
    await tester.tap(find.widgetWithIcon(ElevatedButton, Icons.refresh));
    await pumpSteps(tester);
    expect(api.requests, 2);
    expect(api.polledSessions.last, _secondSessionId);
    expect(api.closes, [_sessionId]);
    await native.candidate(2);
    await native.candidate(3);
    await pumpSteps(tester);
    expect(api.candidates, hasLength(2));
    expect(api.candidates.last.sessionId, _secondSessionId);
    api.candidates.first.done.complete();
    oldPoll.complete({
      'signals': [
        _signal('session_terminate', {'reason': 'recorder_queue_overflow'}),
      ]
    });
    await pumpSteps(tester);
    final polls = api.polls;
    await tester.pump(const Duration(milliseconds: 500));
    expect(api.polls, polls,
        reason: 'Old finally must not unlock the new poll');
    expect(find.textContaining('Recorder'), findsNothing);
    expect(api.candidates, hasLength(2));
    api.candidates[1].done.complete();
    await pumpSteps(tester);
    expect(api.candidates, hasLength(3));
    expect(api.candidates[2].signal['candidate']['candidate'], 'candidate-3');
    expect(api.candidates[2].sessionId, _secondSessionId);
    api.candidates[2].done.complete();
    newPoll.complete({'signals': []});
    await pumpSteps(tester);
    await unmount(tester);
    expect(api.closes, [_sessionId, _secondSessionId]);
  });

  lifecycleTest('host termination cancels an in-flight ICE restart',
      (tester) async {
    api.request.complete({'session_id': _sessionId});
    api.inbound
        .add(_signal('session_answer', {'accepted': true, 'sdp': 'answer'}));
    await mount(tester);
    await native.pc('connected');
    native.localDescriptionGate = Completer<void>();
    await native.pc('disconnected');
    await tester.pump(const Duration(seconds: 2));
    await pumpSteps(tester);
    expect(native.count('createOffer'), 2);
    api.inbound.add(
        _signal('session_terminate', {'reason': 'recorder_queue_overflow'}));
    await tester.pump(const Duration(milliseconds: 500));
    await pumpSteps(tester);
    expect(find.textContaining('Recorder'), findsOneWidget);
    native.localDescriptionGate!.complete();
    await tester.pump(const Duration(seconds: 3));
    await pumpSteps(tester);
    expect(native.count('createOffer'), 2);
    expect(native.count('restartIce'), 0);
    expect(api.otherSignals.where((signal) => signal['type'] == 'ice_restart'),
        isEmpty);
    expect(api.closes, [_sessionId]);
    await unmount(tester);
  });

  lifecycleTest(
      'end timeout, termination, cleanup and dispose share one close future',
      (tester) async {
    api.request.complete({'session_id': _sessionId});
    api.closeResult = Completer<void>();
    await mount(tester);
    await end(tester);
    expect(api.closes, [_sessionId]);
    await tester.pump(const Duration(seconds: 3));
    await pumpSteps(tester);
    await unmount(tester);
    expect(api.closes, [_sessionId]);
    expect(api.legacyEnds, 0);
    api.closeResult!.completeError(ApiException(409, 'ended'));
    await pumpSteps(tester);
    expect(tester.takeException(), isNull);
  });

  for (final claimedSOS in [false, true]) {
    lifecycleTest(
        'failed creation never uses legacy support${claimedSOS ? ' and releases claimed SOS once' : ''}',
        (tester) async {
      await mount(tester,
          data: claimedSOS
              ? {'sos_request_id': 'request', 'sos_session_id': _sessionId}
              : {});
      api.request.completeError(ApiException(403, 'creation_failed'));
      await pumpSteps(tester);
      await end(tester);
      await unmount(tester);
      expect(api.closes, claimedSOS ? [_sessionId] : isEmpty);
      expect(api.legacyEnds, 0);
      expect(native.count('peerConnectionClose'), 1,
          reason: native.calls.map((call) => call.method).join(', '));
      expect(native.count('peerConnectionDispose'), 1);
    });
  }

  lifecycleTest(
      'late successful creation after dispose releases its real session without signaling',
      (tester) async {
    await mount(tester);
    await native.candidate(0);
    await unmount(tester);
    api.request.complete({'session_id': _sessionId});
    await pumpSteps(tester);
    expect(api.closes, [_sessionId]);
    expect(api.legacyEnds, 0);
    expect(api.candidates, isEmpty);
    expect(api.polls, 0);
    expect(api.heartbeats, 0);
    expect(tester.takeException(), isNull);
  });

  lifecycleTest(
      'onTrack is not PC connected; desktop skips iOS audio and catches asynchronous volume/disposal failures',
      (tester) async {
    api.request.complete({'session_id': _sessionId});
    await mount(tester);
    native.errors
        .addAll({'setVolume', 'videoRendererDispose', 'peerConnectionDispose'});
    await native.track('audio');
    await native.track('video', includeAudio: true);
    await pumpSteps(tester);
    expect(native.count('ensureAudioSession'), 0);
    expect(native.count('setVolume'), greaterThanOrEqualTo(2));
    var content = await logContent(tester);
    expect(content, contains('connected=false'));
    expect(content, isNot(contains('connected=true')));
    expect(content, contains('phase=remote_audio_volume'));
    await native.pc('connected');
    await pumpSteps(tester);
    content = await logContent(tester);
    expect(content, contains('pc_state=RTCPeerConnectionStateConnected'));
    await unmount(tester);
    content = await logContent(tester);
    expect(content, contains('phase=renderer_dispose'));
    expect(content, contains('phase=peer_dispose'));
    expect(native.count('dataChannelClose'), 1);
    expect(native.count('peerConnectionDispose'), 1);
  });
}
