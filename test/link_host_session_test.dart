import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ligament_authenticator/screens/link_host_overlay.dart';
import 'package:ligament_authenticator/services/link_host_session.dart';

const _sessionId = '10000000-0000-4000-8000-000000000001';
const _viewOffer = 'v=0\r\nm=video 9 UDP/TLS/RTP/SAVPF 96';
const _controlOffer =
    '$_viewOffer\r\nm=application 9 UDP/DTLS/SCTP webrtc-datachannel';

class _FakeLinkHostPeer implements LinkHostPeer {
  Completer<String>? startGate;
  void Function(Map<String, dynamic>)? candidateCallback;
  void Function()? failureCallback;
  final List<Map<String, dynamic>> candidates = [];
  bool allowControl = false;
  int closeCount = 0;

  @override
  Future<String> start({
    required String offerSdp,
    required List<Map<String, dynamic>> iceServers,
    required bool allowControl,
    required void Function(Map<String, dynamic>) onCandidate,
    required void Function() onFailure,
  }) {
    this.allowControl = allowControl;
    candidateCallback = onCandidate;
    failureCallback = onFailure;
    return startGate?.future ?? Future.value('v=0 answer');
  }

  @override
  Future<void> addRemoteCandidate(Map<String, dynamic> candidate) async {
    candidates.add(candidate);
  }

  @override
  Future<void> close() async {
    closeCount++;
  }
}

void main() {
  test('Link worker pipe argument accepts only generated local pipe names', () {
    const pipe = r'\\.\pipe\LigamentLinkHost-0123456789abcdef0123456789abcdef';
    expect(linkHostPipeFromArgs(const []), isNull);
    expect(linkHostPipeFromArgs(['--link-host=$pipe']), pipe);
    expect(() => linkHostPipeFromArgs(['--link-host=\\\\.\\pipe\\other']),
        throwsFormatException);
    expect(
      () => linkHostPipeFromArgs(['--link-host=$pipe', '--link-host=$pipe']),
      throwsFormatException,
    );
  });

  test('Unix Link worker accepts only private generated socket paths', () {
    const socket = '/tmp/ligament-link-a1b2c3/worker.sock';
    expect(linkHostUnixSocketFromArgs(const []), isNull);
    expect(
      linkHostUnixSocketFromArgs(['--link-host=unix:$socket']),
      socket,
    );
    expect(
      () => linkHostUnixSocketFromArgs(
        const ['--link-host=unix:/tmp/other/worker.sock'],
      ),
      throwsFormatException,
    );
    expect(
      () => linkHostUnixSocketFromArgs(
        const [
          '--link-host=unix:/tmp/ligament-link-a1b2c3/worker.sock',
          '--link-host=unix:/tmp/ligament-link-d4e5f6/worker.sock',
        ],
      ),
      throwsFormatException,
    );
  });

  test('host privacy indicator can locally terminate the session', () async {
    final state = LinkHostWorkerState();
    state.showSession(_sessionId, 'control', 'operator@example.com');
    state.markActive();

    expect(state.phase, LinkHostWorkerPhase.active);
    expect(state.accessMode, 'control');
    expect(state.operatorName, 'operator@example.com');
    state.requestDisconnect();
    await state.disconnectRequested;
    expect(state.phase, LinkHostWorkerPhase.closing);
  });

  test('attended request remains blocked until local approval', () async {
    final state = LinkHostWorkerState();
    state.showSession(_sessionId, 'control', 'operator@example.com');
    final decision = state.awaitConsent();
    expect(state.phase, LinkHostWorkerPhase.awaitingConsent);
    state.approveConsent();
    expect(await decision, isTrue);
    expect(state.phase, LinkHostWorkerPhase.connecting);
  });

  test('local denial fails closed', () async {
    final state = LinkHostWorkerState();
    state.showSession(_sessionId, 'view', 'operator@example.com');
    final decision = state.awaitConsent();
    state.denyConsent();
    expect(await decision, isFalse);
    expect(state.phase, LinkHostWorkerPhase.closing);
  });

  testWidgets('privacy indicator stays visible and disconnects on request',
      (tester) async {
    const windowChannel = MethodChannel('window_manager');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      windowChannel,
      (call) async => null,
    );
    addTearDown(() => messenger.setMockMethodCallHandler(windowChannel, null));

    final state = LinkHostWorkerState()
      ..showSession(_sessionId, 'control', 'Иванов Иван')
      ..markActive();
    await tester.pumpWidget(LinkHostOverlay(state: state));
    await tester.pump();

    expect(find.text('Удалённая сессия активна'), findsOneWidget);
    expect(find.text('Иванов Иван · Управление'), findsOneWidget);
    await tester.tap(find.text('Отключить'));
    await tester.pump();

    expect(state.phase, LinkHostWorkerPhase.closing);
    expect(find.text('Отключение…'), findsOneWidget);
  });

  testWidgets('attended request shows explicit approve and deny actions',
      (tester) async {
    const windowChannel = MethodChannel('window_manager');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(windowChannel, (call) async => null);
    addTearDown(() => messenger.setMockMethodCallHandler(windowChannel, null));

    final state = LinkHostWorkerState()
      ..showSession(_sessionId, 'control', 'Иванов Иван');
    final decision = state.awaitConsent();
    await tester.pumpWidget(LinkHostOverlay(state: state));
    expect(find.text('Разрешить удалённое подключение?'), findsOneWidget);
    expect(find.text('Разрешить'), findsOneWidget);
    expect(find.text('Отклонить'), findsOneWidget);
    await tester.tap(find.text('Отклонить'));
    expect(await decision, isFalse);
  });

  test('answers offer with session-scoped envelope and forwards ICE', () async {
    final peer = _FakeLinkHostPeer();
    final sent = <Map<String, dynamic>>[];
    final session = LinkHostSession(
      sessionId: _sessionId,
      accessMode: 'control',
      peer: peer,
      send: (frame) async => sent.add(frame),
    );

    await session.start(
      offerSdp: _controlOffer,
      iceServers: const [],
      consentGranted: true,
    );
    peer.candidateCallback!({'candidate': 'candidate:1'});
    await Future<void>.delayed(Duration.zero);

    expect(peer.allowControl, isTrue);
    expect(sent[0], {
      'type': 'session_answer',
      'session_id': _sessionId,
      'payload': {
        'session_id': _sessionId,
        'accepted': true,
        'consent_granted': true,
        'sdp': 'v=0 answer',
      },
    });
    expect(sent[1], {
      'type': 'signal',
      'session_id': _sessionId,
      'signal': {
        'candidate': {'candidate': 'candidate:1'}
      },
    });
  });

  test('buffers early candidates and applies them after local answer',
      () async {
    final peer = _FakeLinkHostPeer()..startGate = Completer<String>();
    final sent = <Map<String, dynamic>>[];
    final session = LinkHostSession(
      sessionId: _sessionId,
      accessMode: 'view',
      peer: peer,
      send: (frame) async => sent.add(frame),
    );
    final starting = session.start(offerSdp: _viewOffer, iceServers: const []);

    await session.receive({
      'type': 'signal',
      'session_id': _sessionId,
      'signal': {
        'candidate': {'candidate': 'candidate:early'}
      },
    });
    expect(peer.candidates, isEmpty);
    peer.startGate!.complete('v=0 answer');
    await starting;

    expect(peer.allowControl, isFalse);
    expect(peer.candidates, [
      {'candidate': 'candidate:early'},
    ]);
    expect(sent.single['type'], 'session_answer');
  });

  test('rejects cross-session signaling and closes the worker', () async {
    final peer = _FakeLinkHostPeer();
    final sent = <Map<String, dynamic>>[];
    final session = LinkHostSession(
      sessionId: _sessionId,
      accessMode: 'view',
      peer: peer,
      send: (frame) async => sent.add(frame),
    );
    await session.start(offerSdp: _viewOffer, iceServers: const []);
    await session.receive({
      'type': 'signal',
      'session_id': '20000000-0000-4000-8000-000000000002',
      'signal': {
        'candidate': {'candidate': 'candidate:cross-session'}
      },
    });

    expect(session.isClosed, isTrue);
    expect(peer.closeCount, 1);
    expect(sent, hasLength(1));
    expect((sent.single['payload'] as Map)['accepted'], isTrue);
  });

  test('rejects oversized SDP before starting peer', () async {
    final peer = _FakeLinkHostPeer();
    final sent = <Map<String, dynamic>>[];
    final session = LinkHostSession(
      sessionId: _sessionId,
      accessMode: 'view',
      peer: peer,
      send: (frame) async => sent.add(frame),
    );

    await session.start(
      offerSdp: 'x' * (LinkHostSession.maxOfferSdpBytes + 1),
      iceServers: const [],
    );
    expect(peer.candidateCallback, isNull);
    expect(session.isClosed, isTrue);
    expect((sent.single['payload'] as Map)['reason'], 'invalid_offer');
  });

  test('control offer requires the negotiated DataChannel media section',
      () async {
    final peer = _FakeLinkHostPeer();
    final sent = <Map<String, dynamic>>[];
    final rejecting = LinkHostSession(
      sessionId: _sessionId,
      accessMode: 'control',
      peer: peer,
      send: (frame) async => sent.add(frame),
    );
    await rejecting.start(offerSdp: _viewOffer, iceServers: const []);
    expect(peer.candidateCallback, isNull);
    expect((sent.single['payload'] as Map)['reason'], 'invalid_offer_media');
  });
}
