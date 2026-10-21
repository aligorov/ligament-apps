import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ligament_authenticator/screens/link_host_overlay.dart';
import 'package:ligament_authenticator/screens/support_approval_modal.dart';
import 'package:ligament_authenticator/services/link_host_session.dart';
import 'package:ligament_authenticator/services/link_host_readiness.dart';

const _id = '10000000-0000-4000-8000-000000000001';

class _Peer implements LinkHostPeer {
  LinkHostReadinessException? failure;
  int starts = 0;
  @override
  Future<String> start(
      {required String offerSdp,
      required List<Map<String, dynamic>> iceServers,
      required bool allowControl,
      required void Function(Map<String, dynamic>) onCandidate,
      required void Function() onFailure}) async {
    starts++;
    if (failure != null) throw failure!;
    return 'v=0 answer';
  }

  @override
  Future<void> addRemoteCandidate(Map<String, dynamic> candidate) async {}
  @override
  Future<void> close() async {}
}

void main() {
  test('typed readiness reason survives host answer normalization', () async {
    final peer = _Peer()
      ..failure = const LinkHostReadinessException(
          'host_accessibility_permission_required');
    final sent = <Map<String, dynamic>>[];
    final session = LinkHostSession(
        sessionId: _id,
        accessMode: 'view',
        peer: peer,
        send: (frame) async => sent.add(frame));
    await session.start(
        offerSdp: 'v=0\r\nm=video 9 UDP/TLS/RTP/SAVPF 96', iceServers: []);
    expect((sent.single['payload'] as Map)['reason'],
        'host_accessibility_permission_required');
    expect(session.isClosed, true);
  });
  for (final authorized in [true, false]) {
    test('media waits for server decision authorized=$authorized', () async {
      final peer = _Peer();
      final sent = <Map<String, dynamic>>[];
      final requestSent = Completer<void>();
      final session = LinkHostSession(
          sessionId: _id,
          accessMode: 'view',
          peer: peer,
          send: (frame) async {
            sent.add(frame);
            if ((frame['payload'] as Map?)?['stage'] == 'consent') {
              requestSent.complete();
            }
          });
      final starting = session.start(
          offerSdp: 'v=0\r\nm=video 9 UDP/TLS/RTP/SAVPF 96',
          iceServers: [],
          consentGranted: true,
          confirmationRequired: true,
          confirmationCode: '27');
      await requestSent.future;
      expect(peer.starts, 0);
      // An operator can send arbitrary signals, but cannot know the private nonce.
      await session.receive({
        'type': 'signal',
        'session_id': _id,
        'signal': {
          'type': 'consent_decision',
          'authorized': true,
          'consent_nonce': 'forged'
        }
      });
      expect(peer.starts, 0);
      final nonce = (sent.first['payload'] as Map)['consent_nonce'];
      await session.receive({
        'type': 'signal',
        'session_id': _id,
        'signal': {
          'type': 'consent_decision',
          'authorized': authorized,
          'consent_nonce': nonce
        }
      });
      await starting;
      expect(peer.starts, authorized ? 1 : 0);
      expect((sent.last['payload'] as Map).containsKey('confirmation_code'),
          false);
      await session.close();
    });
  }

  test('missing code and consent never start media', () async {
    for (final consent in [true, false]) {
      final peer = _Peer();
      final session = LinkHostSession(
          sessionId: _id, accessMode: 'view', peer: peer, send: (_) async {});
      await session.start(
          offerSdp: 'v=0',
          iceServers: [],
          confirmationRequired: true,
          consentGranted: consent);
      expect(peer.starts, 0);
      expect(session.isClosed, true);
    }
  });

  testWidgets('host enters code before explicit consent', (tester) async {
    const channel = MethodChannel('window_manager');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (_) async => null);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final state = LinkHostWorkerState()..showSession(_id, 'view', 'Оператор');
    final consent = state.awaitConsent();
    await tester.pumpWidget(LinkHostOverlay(state: state));
    expect(find.byType(SupportApprovalModal), findsOneWidget);
    expect(
        tester
            .widget<TextField>(
                find.byKey(const Key('support-number-match-code')))
            .maxLength,
        2);
    expect(find.text('27'), findsNothing);
    final approve = find.widgetWithText(ElevatedButton, 'Разрешить доступ');
    expect(tester.widget<ElevatedButton>(approve).onPressed, isNull);
    await tester.enterText(
        find.byKey(const Key('support-number-match-code')), '27');
    await tester.pump();
    expect(state.phase, LinkHostWorkerPhase.awaitingConsent);
    await tester.ensureVisible(approve);
    await tester.tap(approve);
    expect(await consent, true);
    expect(state.confirmationCode, '27');
    state.markClosed();
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
