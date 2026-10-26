import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ligament_authenticator/services/debug_log_service.dart';
import 'package:ligament_authenticator/services/link_host_recorder.dart';
import 'package:ligament_authenticator/services/link_host_session.dart';
import 'package:ligament_authenticator/services/support_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _sessionId = '10000000-0000-4000-8000-000000000001';
const _offer = 'v=0\r\nm=video 9 UDP/TLS/RTP/SAVPF 96\r\n'
    'm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n'
    'a=ice-pwd:private-offer-secret';

class _Peer implements LinkHostPeer {
  Object? startError;
  void Function(Map<String, dynamic>)? candidate;
  int closeCount = 0;

  @override
  Future<String> start({
    required String offerSdp,
    required List<Map<String, dynamic>> iceServers,
    required bool allowControl,
    required void Function(Map<String, dynamic>) onCandidate,
    required void Function() onFailure,
  }) async {
    candidate = onCandidate;
    if (startError != null) throw startError!;
    return 'private-answer-secret';
  }

  @override
  Future<String> renegotiateOffer(String offerSdp) async =>
      'private-answer-secret';

  @override
  Future<void> addRemoteCandidate(Map<String, dynamic> candidate) async {}

  @override
  Future<void> close() async => closeCount++;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late DebugLogService logs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory =
        await Directory.systemTemp.createTemp('support-instrumentation-');
    logs =
        DebugLogService(nativeWindows: false, directory: () async => directory);
    await logs.setEnabled(true);
  });

  tearDown(() async {
    await logs.flush();
    await directory.delete(recursive: true);
  });

  Future<String> content() async {
    await logs.flush();
    return File(logs.path!).readAsString();
  }

  void expectNoPayload(String text) {
    for (final secret in [
      'private-offer-secret',
      'private-answer-secret',
      'private-candidate-secret',
      '284917',
      'private-error-secret',
      'private-frame-secret',
    ]) {
      expect(text, isNot(contains(secret)));
    }
    expect(text, isNot(contains('sdp=')));
    expect(text, isNot(contains('confirmation_code=')));
  }

  test('wire type diagnostics recognize protocol labels, not arbitrary text',
      () {
    for (final type in [
      'mouse_move',
      'file_chunk',
      'clipboard_set',
      'session_answer'
    ]) {
      expect(supportDebugMessageType(type), type);
    }
    for (final value in [
      null,
      27,
      {'type': 'ping'},
      'private-error-secret',
      'Bearer token'
    ]) {
      expect(supportDebugMessageType(value), 'unknown');
    }
  });

  test(
      'host logs authorization and enqueue milestones without SDP or consent digits',
      () async {
    final peer = _Peer();
    late LinkHostSession session;
    session = LinkHostSession(
      sessionId: _sessionId,
      accessMode: 'control',
      peer: peer,
      debugLog: logs,
      send: (frame) async {
        final payload = frame['payload'];
        if (payload is Map && payload['stage'] == 'consent') {
          await session.receive({
            'type': 'signal',
            'session_id': _sessionId,
            'signal': {
              'type': 'consent_decision',
              'consent_nonce': payload['consent_nonce'],
              'authorized': true
            },
          });
        }
      },
    );
    await session.start(
        offerSdp: _offer,
        iceServers: const [],
        consentGranted: true,
        confirmationRequired: true,
        confirmationCode: '284917');
    peer.candidate!({'candidate': 'private-candidate-secret'});
    await Future<void>.delayed(Duration.zero);
    await session.close();
    final text = await content();
    expect(text, contains('event=link.authorization'));
    expect(text, contains('result=allowed'));
    expect(text, contains('event=link.peer.answer_ready'));
    expect(text, contains('duration_ms='));
    expect(text, contains('event=link.session.ready'));
    expect(text, contains('result=queued'));
    expect(text, contains('session_id=$_sessionId'));
    // Answer/IPC readiness is not evidence that a remote peer is connected.
    expect(text, isNot(contains('connected=true')));
    expectNoPayload(text);
  });

  test(
      'host capture failure retains phase and rejection, not exception message',
      () async {
    final peer = _Peer()
      ..startError = PlatformException(
          code: 'capture_unavailable', message: 'private-error-secret');
    final session = LinkHostSession(
        sessionId: _sessionId,
        accessMode: 'control',
        peer: peer,
        debugLog: logs,
        send: (_) async {});
    await session.start(offerSdp: _offer, iceServers: const []);
    final text = await content();
    expect(text, contains('event=link.start.failed'));
    expect(text, contains('phase=peer_start'));
    expect(text, contains('error_type=PlatformException'));
    expect(text, contains('reason=host_worker_failed'));
    expect(text, isNot(contains('event=link.session.ready')));
    expect(peer.closeCount, 1);
    expectNoPayload(text);
  });

  test(
      'failed answer send is never recorded as session readiness or remote ACK',
      () async {
    var sends = 0;
    final session = LinkHostSession(
        sessionId: _sessionId,
        accessMode: 'control',
        peer: _Peer(),
        debugLog: logs,
        send: (_) async {
          if (++sends == 1) throw const SocketException('private-error-secret');
        });
    await session.start(offerSdp: _offer, iceServers: const []);
    final text = await content();
    expect(text, contains('phase=answer_send'));
    expect(text, contains('result=failed'));
    expect(text, contains('error_type=SocketException'));
    expect(text, isNot(contains('event=link.session.ready')));
    expect(text, isNot(contains('result=delivered')));
    expect(text, isNot(contains('result=acked')));
    expectNoPayload(text);
  });

  test('recorder logs partial ACK and remaining queue without frame contents',
      () async {
    final frame = Uint8List.fromList('private-frame-secret'.codeUnits);
    var acknowledgeAll = false;
    final recorder = LinkHostRecorder(
        sessionId: _sessionId,
        debugLog: logs,
        config: const LinkRecordingConfig(enabled: true),
        sendBatch: (batch) async => LinkRecorderBatchAck(
              ackHighWatermarkSeq: acknowledgeAll ? 3 : 1,
              firstFrameAcked: acknowledgeAll,
              leaseExpiresAt: DateTime.now().add(const Duration(seconds: 45)),
            ));
    recorder.start();
    recorder.enqueueFrame(
        frameKind: 'keyframe', payload: frame, width: 800, height: 600);
    expect(await recorder.flushAndVerifyHealth(), isTrue);
    expect(recorder.ackedSeq, 1);
    // Existing queue accounting estimates decoded size from base64 length.
    // Instrumentation must report that value, not change queue accounting.
    expect(recorder.queuedBytes, greaterThanOrEqualTo(frame.length));
    final text = await content();
    expect(text, contains('event=recorder.batch.send'));
    expect(text, contains('event=recorder.batch.ack_received'));
    expect(text, contains('event=recorder.batch.ack_validated'));
    expect(text, contains('acked_seq=1'));
    expect(text, contains('queue_bytes=${recorder.queuedBytes}'));
    expect(text, contains('first_frame_acked=false'));
    expect(text, contains('rtt_ms='));
    expectNoPayload(text);
    acknowledgeAll = true;
    expect(await recorder.stop(reason: 'session_ended'), isTrue);
  });

  test(
      'recorder transport failure and mandatory violation have distinct diagnostics',
      () async {
    var now = DateTime.utc(2026, 10, 23);
    final recorder = LinkHostRecorder(
        sessionId: _sessionId,
        debugLog: logs,
        config: const LinkRecordingConfig(
            enabled: true,
            mandatory: true,
            requireFirstFrame: true,
            maxAckLag: Duration(seconds: 5)),
        clock: () => now,
        sendBatch: (_) async =>
            throw const SocketException('private-error-secret'));
    recorder.start();
    now = now.add(const Duration(seconds: 6));
    expect(await recorder.flushAndVerifyHealth(), isFalse);
    expect(recorder.ackedSeq, 0);
    final text = await content();
    expect(text, contains('event=recorder.batch.failed'));
    expect(text, contains('event=recorder.mandatory.violation'));
    expect(text, contains('reason=recorder_first_frame_unavailable'));
    expect(text, isNot(contains('event=recorder.batch.ack_validated')));
    expectNoPayload(text);
    await recorder.stop(reason: 'session_ended');
  });
}
