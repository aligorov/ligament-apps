import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ligament_authenticator/screens/link_host_overlay.dart';
import 'package:ligament_authenticator/services/link_host_session.dart';
import 'package:ligament_authenticator/models/link_session_policy.dart';

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
  Future<String> renegotiateOffer(String offerSdp) async {
    renegotiatedOffers.add(offerSdp);
    return 'v=0 answer-renegotiated';
  }

  final List<String> renegotiatedOffers = [];

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
    state.approveConsent('27');
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
    expect(find.text('Свернуть в трей'), findsOneWidget);
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
    expect(find.text('Запрос на управление вашим ПК'), findsOneWidget);
    expect(find.text('Разрешить доступ'), findsOneWidget);
    expect(find.text('Отклонить'), findsOneWidget);
    await tester.ensureVisible(find.text('Отклонить'));
    await tester.tap(find.text('Отклонить'));
    expect(await decision, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
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
        'type': 'candidate',
        'candidate': {'candidate': 'candidate:1'}
      },
    });
    // Exercise the operator's actual normalizer after server persistence.
    final signal = Map<String, dynamic>.from(sent[1]['signal'] as Map);
    expect(linkSignalType({'type': signal['type'], 'payload': signal}, signal),
        'candidate');
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

  test('renegotiates ice_restart offer on active session and sends new answer',
      () async {
    final peer = _FakeLinkHostPeer();
    final sent = <Map<String, dynamic>>[];
    final session = LinkHostSession(
      sessionId: _sessionId,
      accessMode: 'control',
      peer: peer,
      send: (frame) async => sent.add(frame),
    );
    await session.start(offerSdp: _controlOffer, iceServers: const []);
    expect(sent, hasLength(1));

    await session.receive({
      'type': 'signal',
      'session_id': _sessionId,
      'signal': {
        'type': 'ice_restart',
        'sdp': '$_controlOffer\r\na=ice-ufrag:newufrag',
      },
    });

    expect(peer.renegotiatedOffers, hasLength(1));
    expect(sent, hasLength(2));
    expect(sent.last['type'], 'session_answer');
    expect((sent.last['payload'] as Map)['sdp'], 'v=0 answer-renegotiated');
    expect(session.isClosed, isFalse);
  });

  test('isValidControlInput validates all 6 operator toolbar commands', () {
    expect(
      LinkHostSession.isValidControlInput({
        'type': 'text_input',
        'text': 'Hello World',
      }),
      isTrue,
    );
    expect(
      LinkHostSession.isValidControlInput({
        'type': 'video_quality',
        'quality': 'best',
      }),
      isTrue,
    );
    expect(
      LinkHostSession.isValidControlInput({
        'type': 'reboot',
      }),
      isTrue,
    );
    expect(
      LinkHostSession.isValidControlInput({
        'type': 'file_start',
        'transfer_id': 'tx-1',
        'filename': 'report.pdf',
        'size': 1024,
        'total_chunks': 1,
      }),
      isTrue,
    );
    expect(
      LinkHostSession.isValidControlInput({
        'type': 'file_chunk',
        'transfer_id': 'tx-1',
        'chunk_index': 0,
        'data': 'YWJj',
      }),
      isTrue,
    );
    expect(
      LinkHostSession.isValidControlInput({
        'type': 'file_end',
        'transfer_id': 'tx-1',
      }),
      isTrue,
    );
    expect(
      LinkHostSession.isValidControlInput({
        'type': 'chat_message',
        'text': 'Здравствуйте, чем могу помочь?',
      }),
      isTrue,
    );
    expect(
      LinkHostSession.isValidControlInput({
        'type': 'chat_message',
        'text': '   ',
      }),
      isFalse,
    );
    expect(
      LinkHostSession.isValidControlInput({
        'type': 'chat_message',
        'text': 'a' * 4097,
      }),
      isFalse,
    );
  });

  test('LinkHostWorkerState handles bidirectional chat and unread counters',
      () {
    final state = LinkHostWorkerState();
    final sentMessages = <Map<String, dynamic>>[];
    state.bindChatSender((msg) => sentMessages.add(msg));

    expect(state.chatMessages, isEmpty);
    expect(state.unreadChatCount, 0);

    // Host sends message to operator
    state.sendChatMessage('Привет оператор!');
    expect(state.chatMessages, hasLength(1));
    expect(state.chatMessages.first.text, 'Привет оператор!');
    expect(state.chatMessages.first.sender, 'user');
    expect(sentMessages, hasLength(1));
    expect(sentMessages.first['type'], 'chat_message');
    expect(sentMessages.first['text'], 'Привет оператор!');
    expect(sentMessages.first['client_id'], isNotEmpty);
    expect(state.unreadChatCount, 0); // Outgoing does not increment unread

    // Incoming message from operator
    final now = DateTime.now();
    state.receiveChatMessage({
      'type': 'chat_message',
      'id': 'op-1',
      'sender': 'operator',
      'sender_name': 'Инженер Поддержки',
      'text': 'Здравствуйте!',
      'timestamp': now.millisecondsSinceEpoch,
      'client_id': 'client-op-1',
    });
    expect(state.chatMessages, hasLength(2));
    expect(state.unreadChatCount, 1);

    // Duplicate message is ignored
    state.receiveChatMessage({
      'type': 'chat_message',
      'id': 'op-1',
      'sender': 'operator',
      'sender_name': 'Инженер Поддержки',
      'text': 'Здравствуйте!',
      'timestamp': now.millisecondsSinceEpoch,
      'client_id': 'client-op-1',
    });
    expect(state.chatMessages, hasLength(2));
    expect(state.unreadChatCount, 1);

    // Intentional repeat messages with distinct client_ids are preserved (V-06)
    state.receiveChatMessage({
      'type': 'chat_message',
      'id': 'op-2',
      'sender': 'operator',
      'sender_name': 'Инженер Поддержки',
      'text': 'Да',
      'timestamp': now.add(const Duration(seconds: 1)).millisecondsSinceEpoch,
      'client_id': 'client-op-2',
    });
    state.receiveChatMessage({
      'type': 'chat_message',
      'id': 'op-3',
      'sender': 'operator',
      'sender_name': 'Инженер Поддержки',
      'text': 'Да',
      'timestamp': now.add(const Duration(seconds: 2)).millisecondsSinceEpoch,
      'client_id': 'client-op-3',
    });
    expect(state.chatMessages, hasLength(4));

    // Clear unread
    state.clearUnreadChat();
    expect(state.unreadChatCount, 0);
  });

  test('attended consent fails immediately when the window is unavailable',
      () async {
    final state = LinkHostWorkerState()
      ..markConsentUiUnavailable()
      ..showSession(_sessionId, 'control', 'operator@example.com');

    expect(await state.awaitConsent(), isFalse);
    expect(state.consentUiAvailable, isFalse);
  });

  test('window failure during consent completes denial without a timeout',
      () async {
    final state = LinkHostWorkerState()
      ..showSession(_sessionId, 'control', 'operator@example.com');
    final decision = state.awaitConsent();

    state.markConsentUiUnavailable();

    expect(await decision, isFalse);
    expect(state.phase, LinkHostWorkerPhase.closing);
  });

  test('media failure after accepted answer emits session termination',
      () async {
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
    sent.clear();

    peer.failureCallback!();
    await Future<void>.delayed(Duration.zero);

    expect(sent, hasLength(1));
    expect(sent.single['type'], 'session_terminate');
    expect((sent.single['payload'] as Map)['reason'], 'host_media_failed');
    expect(session.isClosed, isTrue);
  });

  testWidgets('consent window retries after a transient show failure',
      (tester) async {
    const windowChannel = MethodChannel('window_manager');
    const screenChannel = MethodChannel('screen_retriever');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var showAttempts = 0;
    messenger.setMockMethodCallHandler(windowChannel, (call) async {
      if (call.method == 'isMinimized') return false;
      if (call.method == 'getBounds') {
        return {'x': 0.0, 'y': 0.0, 'width': 560.0, 'height': 760.0};
      }
      if (call.method == 'show') {
        showAttempts++;
        if (showAttempts == 1) {
          throw PlatformException(code: 'show_failed');
        }
      }
      return null;
    });
    const display = {
      'id': 1,
      'name': 'test',
      'size': {'width': 1200.0, 'height': 800.0},
      'visiblePosition': {'x': 0.0, 'y': 0.0},
      'visibleSize': {'width': 1200.0, 'height': 800.0},
      'scaleFactor': 1.0,
    };
    messenger.setMockMethodCallHandler(screenChannel, (call) async {
      if (call.method == 'getPrimaryDisplay') return display;
      if (call.method == 'getAllDisplays') {
        return {'displays': [display]};
      }
      if (call.method == 'getCursorScreenPoint') {
        return {'x': 0.0, 'y': 0.0};
      }
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(windowChannel, null);
      messenger.setMockMethodCallHandler(screenChannel, null);
    });

    final state = LinkHostWorkerState()
      ..showSession(_sessionId, 'control', 'Иванов Иван');
    await tester.pumpWidget(LinkHostOverlay(state: state));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));

    expect(showAttempts, greaterThanOrEqualTo(2));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('LinkHostOverlay toggles chat panel and sends messages',
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
      ..showSession(_sessionId, 'control', 'Оператор')
      ..markActive();
    final sent = <Map<String, dynamic>>[];
    state.bindChatSender((m) => sent.add(m));

    await tester.pumpWidget(LinkHostOverlay(state: state));
    await tester.pump();

    // Chat button is visible
    expect(find.text('Чат'), findsOneWidget);
    expect(find.text('Введите сообщение…'), findsNothing);

    // Open chat
    await tester.tap(find.text('Чат'));
    await tester.pump();

    expect(find.text('Закрыть чат'), findsOneWidget);
    expect(find.text('Введите сообщение…'), findsOneWidget);
    expect(find.text('Нет сообщений. Напишите оператору.'), findsOneWidget);

    // Type and send message
    await tester.enterText(find.byType(TextField), 'Проверка связи');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();

    expect(sent, hasLength(1));
    expect(sent.first['text'], 'Проверка связи');
    expect(find.text('Проверка связи'), findsOneWidget);

    // Close chat
    await tester.tap(find.text('Закрыть чат'));
    await tester.pump();

    expect(find.text('Чат'), findsOneWidget);
    expect(find.text('Введите сообщение…'), findsNothing);
  });
}
