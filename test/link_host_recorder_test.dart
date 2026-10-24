import 'dart:async';
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

  test('skips duplicate periodic idle frames on host while maintaining lease keepalive', () async {
    var currentNow = DateTime.utc(2026, 10, 23, 12, 0);
    final sentBatches = <Map<String, dynamic>>[];

    late final LinkHostRecorder recorder;
    recorder = LinkHostRecorder(
      sessionId: '9b1deb4d-3b7d-4bad-9bdd-2b0d7b3dcb6d',
      config: const LinkRecordingConfig(
        enabled: true,
        mandatory: true,
        requireFirstFrame: true,
        effectiveMode: 'record_only',
        maxAckLag: Duration(seconds: 30),
      ),
      clock: () => currentNow,
      sendBatch: (batch) async {
        sentBatches.add(batch);
        return LinkRecorderBatchAck(
          ackHighWatermarkSeq: recorder.nextSeq,
          firstFrameAcked: true,
          leaseExpiresAt: currentNow.add(const Duration(seconds: 45)),
        );
      },
    );

    final staticPixels = Uint8List.fromList([10, 20, 30, 40]);
    final changedPixels = Uint8List.fromList([99, 88, 77, 66]);

    recorder.enqueueFrame(frameKind: 'keyframe', payload: staticPixels);
    recorder.enqueueFrame(frameKind: 'periodic', payload: staticPixels);
    recorder.enqueueFrame(frameKind: 'periodic', payload: staticPixels);
    recorder.enqueueFrame(frameKind: 'periodic', payload: changedPixels);

    // Должны быть поставлены только seq=1 (keyframe) и seq=2 (изменившийся periodic)
    expect(recorder.nextSeq, 2);
    final ok = await recorder.flushAndVerifyHealth();
    expect(ok, isTrue);
    expect(sentBatches.length, 1);
    expect((sentBatches.first['frames'] as List).length, 2);
  });

  test('parseImageHeader correctly decodes PNG dimensions and codec', () {
    final pngHeader = Uint8List.fromList([
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // magic
      0x00, 0x00, 0x00, 0x0D, // IHDR chunk len 13
      0x49, 0x48, 0x44, 0x52, // IHDR
      0x00, 0x00, 0x05, 0x00, // width: 1280 (0x0500)
      0x00, 0x00, 0x02, 0xD0, // height: 720 (0x02D0)
      0x08, 0x06, 0x00, 0x00, 0x00,
    ]);
    final info = parseImageHeader(pngHeader);
    expect(info, isNotNull);
    expect(info!.codec, 'png');
    expect(info.width, 1280);
    expect(info.height, 720);
  });

  test('parseImageHeader correctly decodes JPEG dimensions and codec', () {
    final jpegHeader = Uint8List.fromList([
      0xFF, 0xD8, // SOI
      0xFF, 0xE0, 0x00, 0x10, // APP0 len 16
      0x4A, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00,
      0xFF, 0xC0, 0x00, 0x11, // SOF0 len 17
      0x08, // precision 8
      0x04, 0x38, // height: 1080 (0x0438)
      0x07, 0x80, // width: 1920 (0x0780)
      0x03, 0x01, 0x11, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01,
      0xFF, 0xD9, // EOI
    ]);
    final info = parseImageHeader(jpegHeader);
    expect(info, isNotNull);
    expect(info!.codec, 'jpeg');
    expect(info.width, 1920);
    expect(info.height, 1080);
  });

  test('preserves events added during in-flight sendBatch and deletes only acked seq', () async {
    final currentNow = DateTime.utc(2026, 10, 23, 12, 0);
    final completer = Completer<LinkRecorderBatchAck>();
    final batches = <Map<String, dynamic>>[];

    final recorder = LinkHostRecorder(
      sessionId: '9b1deb4d-3b7d-4bad-9bdd-2b0d7b3dcb6d',
      config: const LinkRecordingConfig(enabled: true),
      clock: () => currentNow,
      sendBatch: (b) {
        batches.add(b);
        if (batches.length == 1) {
          return completer.future;
        }
        return Future.value(LinkRecorderBatchAck(
          ackHighWatermarkSeq: 3,
          firstFrameAcked: true,
          leaseExpiresAt: currentNow.add(const Duration(seconds: 45)),
        ));
      },
    );

    recorder.enqueueFrame(frameKind: 'keyframe', payload: Uint8List.fromList([1, 2, 3])); // seq 1
    recorder.observeControlInput({'type': 'hotkey', 'action': 'test1'}); // seq 2

    // Запускаем отправку первого батча (зависнет на completer)
    final flush1 = recorder.flushAndVerifyHealth();

    // Пока первый батч в полёте, поступает новое событие (seq 3)
    recorder.observeControlInput({'type': 'hotkey', 'action': 'test2'}); // seq 3
    expect(recorder.nextSeq, 3);

    // Завершаем первый батч (сервер подтвердил только seq 2)
    completer.complete(LinkRecorderBatchAck(
      ackHighWatermarkSeq: 2,
      firstFrameAcked: true,
      leaseExpiresAt: currentNow.add(const Duration(seconds: 45)),
    ));
    final ok1 = await flush1;
    expect(ok1, isTrue);
    expect(recorder.ackedSeq, 2);

    // Событие seq 3 НЕ должно быть стёрто: отправляем второй батч
    final ok2 = await recorder.flushAndVerifyHealth();
    expect(ok2, isTrue);
    expect(batches.length, 2);
    final secondEvents = batches[1]['events'] as List;
    expect(secondEvents.length, 1);
    expect(secondEvents.first['seq'], 3);
  });

  test('stop awaits in-flight flush and drains tail events enqueued during flight', () async {
    final completer = Completer<LinkRecorderBatchAck>();
    final batches = <Map<String, dynamic>>[];
    var currentNow = DateTime.utc(2026, 10, 24, 12, 0, 0);

    final recorder = LinkHostRecorder(
      sessionId: '9b1deb4d-3b7d-4bad-9bdd-2b0d7b3dcb6d',
      config: const LinkRecordingConfig(enabled: true),
      clock: () => currentNow,
      sendBatch: (b) {
        batches.add(b);
        if (batches.length == 1) {
          return completer.future;
        }
        return Future.value(LinkRecorderBatchAck(
          ackHighWatermarkSeq: 2,
          firstFrameAcked: true,
          leaseExpiresAt: currentNow.add(const Duration(seconds: 45)),
        ));
      },
    );

    recorder.observeControlInput({'type': 'hotkey', 'action': 'action1'}); // seq 1
    final flushFuture = recorder.flushAndVerifyHealth();

    // Enqueue event while batch 1 is in-flight
    recorder.observeControlInput({'type': 'hotkey', 'action': 'action2'}); // seq 2
    expect(recorder.nextSeq, 2);

    // Call stop() while batch 1 is still in flight
    final stopFuture = recorder.stop();

    // Complete in-flight batch 1 (only acked seq 1)
    completer.complete(LinkRecorderBatchAck(
      ackHighWatermarkSeq: 1,
      firstFrameAcked: true,
      leaseExpiresAt: currentNow.add(const Duration(seconds: 45)),
    ));

    await flushFuture;
    await stopFuture;

    // Both batches must have been sent and seq 2 must be recorded
    expect(batches.length, 2);
    final secondBatchEvents = batches[1]['events'] as List;
    expect(secondBatchEvents.length, 1);
    expect(secondBatchEvents.first['seq'], 2);
    expect(recorder.ackedSeq, 2);
  });

  test('mandatory recording halts session if no first frame acked within lag timeout', () async {
    String? violation;
    var currentNow = DateTime.utc(2026, 10, 24, 12, 0, 0);

    final recorder = LinkHostRecorder(
      sessionId: '9b1deb4d-3b7d-4bad-9bdd-2b0d7b3dcb6d',
      config: const LinkRecordingConfig(
        enabled: true,
        mandatory: true,
        maxAckLag: Duration(seconds: 30),
      ),
      clock: () => currentNow,
      onMandatoryViolation: (r) => violation = r,
      sendBatch: (b) async {
        return LinkRecorderBatchAck(
          ackHighWatermarkSeq: 1,
          firstFrameAcked: false, // only events acked, no video frame!
          leaseExpiresAt: currentNow.add(const Duration(seconds: 45)),
        );
      },
    );

    // Only events enqueued, no frames
    recorder.observeControlInput({'type': 'hotkey', 'action': 'test'});
    await recorder.flushAndVerifyHealth();
    expect(violation, isNull);

    // Advance clock past maxAckLag (35 seconds)
    currentNow = currentNow.add(const Duration(seconds: 35));
    await recorder.flushAndVerifyHealth();

    expect(violation, anyOf('recorder_first_frame_unavailable', 'recorder_first_frame_unacked'));
  });
}
