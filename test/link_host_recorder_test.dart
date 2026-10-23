import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ligament_authenticator/services/link_host_recorder.dart';

void main() {
  test('rejects temporary link_<agentId> session ID', () {
    expect(
      () => LinkHostRecorder(
        sessionId: 'link_12345',
        config: const LinkRecordingConfig(enabled: true),
        sendBatch: (_) async => LinkRecorderBatchAck(
          ackHighWatermarkSeq: 1,
          firstFrameAcked: true,
          leaseExpiresAt: DateTime.now().add(const Duration(seconds: 45)),
        ),
      ),
      throwsFormatException,
    );
  });

  test('records keyboard input, special keys, and sanitizes clipboard text on host', () {
    final now = DateTime.utc(2026, 10, 23, 12, 0);

    // Печатные клавиши оператора записываются как key_input
    final keyEv = LinkHostRecorder.sanitizeInputEvent(
      {'type': 'key_down', 'key': 'p', 'char': 'p'},
      occurredAt: now,
    );
    expect(keyEv, isNotNull);
    expect(keyEv!['event_type'], 'key_input');
    expect((keyEv['metadata'] as Map)['char'], 'p');

    // Отпускание клавиши (key_up) не дублирует запись в журнале
    expect(
      LinkHostRecorder.sanitizeInputEvent(
        {'type': 'key_up', 'key': 'p', 'char': 'p'},
        occurredAt: now,
      ),
      isNull,
    );

    // Специальная клавиша Enter сохраняется как special_key
    final enterEv = LinkHostRecorder.sanitizeInputEvent(
      {'type': 'key_down', 'key': 'Enter', 'char': '\n'},
      occurredAt: now,
    );
    expect(enterEv, isNotNull);
    expect(enterEv!['event_type'], 'special_key');

    // Содержимое буфера обмена вырезается
    final clipEv = LinkHostRecorder.sanitizeInputEvent(
      {'type': 'clipboard_set', 'text': 'TopSecretClipboard'},
      occurredAt: now,
    );
    expect(clipEv, isNotNull);
    expect((clipEv!['metadata'] as Map).containsKey('text'), isFalse);
  });

  test('enforces mandatory first-frame ACK and stops session on ACK lag in P2P', () async {
    var currentNow = DateTime.utc(2026, 10, 23, 12, 0);
    String? stopReason;
    var serverAvailable = true;

    final recorder = LinkHostRecorder(
      sessionId: '9b1deb4d-3b7d-4bad-9bdd-2b0d7b3dcb6d',
      config: const LinkRecordingConfig(
        enabled: true,
        mandatory: true,
        requireFirstFrame: true,
        effectiveMode: 'record_only',
        maxAckLag: Duration(seconds: 15),
        leaseTtl: Duration(seconds: 30),
      ),
      clock: () => currentNow,
      onMandatoryViolation: (reason) => stopReason = reason,
      sendBatch: (batch) async {
        if (!serverAvailable) {
          throw Exception('recorder ingest unreachable');
        }
        return LinkRecorderBatchAck(
          ackHighWatermarkSeq: 2,
          firstFrameAcked: true,
          leaseExpiresAt: currentNow.add(const Duration(seconds: 30)),
        );
      },
    );

    recorder.enqueueFrame(
      frameKind: 'keyframe',
      payload: Uint8List.fromList([1, 2, 3, 4]),
    );
    recorder.observeControlInput({'type': 'hotkey', 'action': 'ctrl_alt_del'});

    final ok1 = await recorder.flushAndVerifyHealth();
    expect(ok1, isTrue);
    expect(recorder.isFirstFrameAcked, isTrue);
    expect(stopReason, isNull);

    // Симулируем потерю только архивного канала при живом P2P WebRTC:
    serverAvailable = false;
    currentNow = currentNow.add(const Duration(seconds: 20)); // > maxAckLag (15s)
    recorder.enqueueFrame(
      frameKind: 'activity',
      payload: Uint8List.fromList([5, 6, 7, 8]),
    );
    final ok2 = await recorder.flushAndVerifyHealth();
    expect(ok2, isFalse);
    expect(stopReason, 'recorder_ack_lag_exceeded');
  });

  test('does not prematurely stop session during startup grace period when no frames yet', () async {
    var currentNow = DateTime.utc(2026, 10, 23, 12, 0);
    String? stopReason;

    final recorder = LinkHostRecorder(
      sessionId: '9b1deb4d-3b7d-4bad-9bdd-2b0d7b3dcb6d',
      config: const LinkRecordingConfig(
        enabled: true,
        mandatory: true,
        requireFirstFrame: true,
        effectiveMode: 'record_only',
        maxAckLag: Duration(seconds: 15),
      ),
      clock: () => currentNow,
      onMandatoryViolation: (reason) => stopReason = reason,
      sendBatch: (_) async => LinkRecorderBatchAck(
        ackHighWatermarkSeq: 0,
        firstFrameAcked: false,
        leaseExpiresAt: currentNow.add(const Duration(seconds: 30)),
      ),
    );

    // В первые 2 секунды (первый тик таймера) очередей нет, сессия не должна падать
    currentNow = currentNow.add(const Duration(seconds: 2));
    final ok1 = await recorder.flushAndVerifyHealth();
    expect(ok1, isTrue);
    expect(stopReason, isNull);

    // Но по истечении maxAckLag (15s) отсутствие первого кадра останавливает обязательную сессию
    currentNow = currentNow.add(const Duration(seconds: 15));
    final ok2 = await recorder.flushAndVerifyHealth();
    expect(ok2, isFalse);
    expect(stopReason, 'recorder_first_frame_unavailable');
  });
}
