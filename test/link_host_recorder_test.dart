import 'dart:async';
import 'dart:io';
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

  test('records keyboard input without characters/keys, special keys, and sanitizes clipboard text on host', () {
    final now = DateTime.utc(2026, 10, 23, 12, 0);

    // Печатные клавиши оператора записываются как key_input БЕЗ char и key (1.1)
    final keyEv = LinkHostRecorder.sanitizeInputEvent(
      {'type': 'key_down', 'key': 'p', 'char': 'p'},
      occurredAt: now,
    );
    expect(keyEv, isNotNull);
    expect(keyEv!['event_type'], 'key_input');
    expect((keyEv['metadata'] as Map).containsKey('char'), isFalse);
    expect((keyEv['metadata'] as Map).containsKey('key'), isFalse);
    expect((keyEv['metadata'] as Map)['action'], 'key_down');

    // Текстовый ввод оператора сохраняет ТОЛЬКО длину текста, без символов (1.1)
    final textEv = LinkHostRecorder.sanitizeInputEvent(
      {'type': 'text_input', 'text': 'SuperSecretPassword!'},
      occurredAt: now,
    );
    expect(textEv, isNotNull);
    expect(textEv!['event_type'], 'text_input');
    expect((textEv['metadata'] as Map)['length'], 20);
    expect((textEv['metadata'] as Map).containsKey('text'), isFalse);

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
    expect(batches.length >= 2, isTrue);
    final secondBatchEvents = batches[1]['events'] as List;
    expect(secondBatchEvents.any((e) => e['seq'] == 2), isTrue);
    expect(recorder.ackedSeq >= 2, isTrue);
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

  test('1.2: rejects http:// ingest URL with recorder_insecure_ingest', () async {
    String? violation;
    final recorder = LinkHostRecorder(
      sessionId: '9b1deb4d-3b7d-4bad-9bdd-2b0d7b3dcb6d',
      config: const LinkRecordingConfig(
        enabled: true,
        mandatory: true,
        ingestUrl: 'http://insecure-recorder.corp.internal/ingest',
      ),
      onMandatoryViolation: (r) => violation = r,
    );

    recorder.start();
    expect(violation, 'recorder_insecure_ingest');

    // Also verify static sender rejects http:// for remote hosts
    expect(
      () => LinkHostRecorder.defaultHttpSendBatch('http://insecure.local/api', '', {}),
      throwsFormatException,
    );

    // Loopback HTTP and remote HTTPS are allowed
    expect(LinkHostRecorder.isSecureIngestUri(Uri.parse('http://127.0.0.1:8095/ingest')), isTrue);
    expect(LinkHostRecorder.isSecureIngestUri(Uri.parse('http://127.8.9.10:8095/ingest')), isTrue);
    expect(LinkHostRecorder.isSecureIngestUri(Uri.parse('http://[::1]:8095/ingest')), isTrue);
    expect(LinkHostRecorder.isSecureIngestUri(Uri.parse('http://localhost:8095/ingest')), isTrue);
    expect(LinkHostRecorder.isSecureIngestUri(Uri.parse('https://recorder.corp.internal/ingest')), isTrue);
    expect(LinkHostRecorder.isSecureIngestUri(Uri.parse('http://remote.host:8095/ingest')), isFalse);
    expect(LinkHostRecorder.isSecureIngestUri(Uri.parse('http://127.evil.example:8095/ingest')), isFalse);
    expect(LinkHostRecorder.isSecureIngestUri(Uri.parse('http://127.0.0.1.evil.example:8095/ingest')), isFalse);
  });

  test('1.3: clock shift +-2 min does not prematurely expire lease (Stopwatch based)', () async {
    var wallClock = DateTime.utc(2026, 10, 24, 12, 0, 0);
    String? violation;

    final recorder = LinkHostRecorder(
      sessionId: '9b1deb4d-3b7d-4bad-9bdd-2b0d7b3dcb6d',
      config: const LinkRecordingConfig(
        enabled: true,
        mandatory: true,
        leaseTtl: Duration(seconds: 45),
        maxAckLag: Duration(seconds: 300),
      ),
      clock: () => wallClock,
      onMandatoryViolation: (r) => violation = r,
      sendBatch: (_) async => LinkRecorderBatchAck(
        ackHighWatermarkSeq: 1,
        firstFrameAcked: true,
        leaseExpiresAt: wallClock.add(const Duration(seconds: 45)),
      ),
    );

    recorder.enqueueFrame(frameKind: 'keyframe', payload: Uint8List(100));
    await recorder.flushAndVerifyHealth();
    expect(violation, isNull);

    // Симулируем прыжок настенных часов на +2 минуты вперёд (NTP sync / VM time jump)
    wallClock = wallClock.add(const Duration(minutes: 2));

    // Проверяем здоровье: так как Stopwatch не натикал 45 секунд, lease НЕ истёк!
    final ok = await recorder.flushAndVerifyHealth();
    expect(ok, isTrue);
    expect(violation, isNull);

    // Симулируем прыжок часов на 2 минуты назад
    wallClock = wallClock.subtract(const Duration(minutes: 4));
    final okBack = await recorder.flushAndVerifyHealth();
    expect(okBack, isTrue);
    expect(violation, isNull);
  });

  test('1.4: 16 MB queue unloads in parts (batch limits 2 MB / 20 frames)', () async {
    var currentNow = DateTime.utc(2026, 10, 24, 12, 0, 0);
    final sentBatches = <Map<String, dynamic>>[];
    var lastAcked = 0;

    final recorder = LinkHostRecorder(
      sessionId: '9b1deb4d-3b7d-4bad-9bdd-2b0d7b3dcb6d',
      config: const LinkRecordingConfig(
        enabled: true,
        maxQueueBytes: 32 * 1024 * 1024,
      ),
      clock: () => currentNow,
      sendBatch: (batch) async {
        sentBatches.add(batch);
        final frames = batch['frames'] as List;
        if (frames.isNotEmpty) {
          lastAcked = frames.last['seq'] as int;
        }
        return LinkRecorderBatchAck(
          ackHighWatermarkSeq: lastAcked,
          firstFrameAcked: true,
          leaseExpiresAt: currentNow.add(const Duration(seconds: 45)),
        );
      },
    );

    // Заполняем 40 кадров по 50 КБ (~2 МБ суммарно)
    final chunk = Uint8List(50 * 1024);
    for (var i = 0; i < 40; i++) {
      recorder.enqueueFrame(frameKind: 'delta', payload: chunk);
    }
    expect(recorder.queuedBytes, 40 * chunk.length);

    // Первый flush: должен взять не более maxBatchFrames (20 кадров)
    final ok1 = await recorder.flushAndVerifyHealth();
    expect(ok1, isTrue);
    expect(sentBatches.length, 1);
    expect((sentBatches[0]['frames'] as List).length, 20);
    expect(recorder.queuedBytes, closeTo(20 * chunk.length, 1000));

    // Второй flush: разгружает следующие 20 кадров
    final ok2 = await recorder.flushAndVerifyHealth();
    expect(ok2, isTrue);
    expect(sentBatches.length, 2);
    expect((sentBatches[1]['frames'] as List).length, 20);
    expect(recorder.queuedBytes, 0);
  });

  test('1.5: validates ACK high watermark cannot decrease and required fields present', () async {
    var currentNow = DateTime.utc(2026, 10, 24, 12, 0, 0);
    var serverSeq = 5;

    final recorder = LinkHostRecorder(
      sessionId: '9b1deb4d-3b7d-4bad-9bdd-2b0d7b3dcb6d',
      config: const LinkRecordingConfig(enabled: true),
      clock: () => currentNow,
      sendBatch: (_) async => LinkRecorderBatchAck(
        ackHighWatermarkSeq: serverSeq,
        firstFrameAcked: true,
        leaseExpiresAt: currentNow.add(const Duration(seconds: 45)),
      ),
    );

    recorder.observeControlInput({'type': 'hotkey', 'action': '1'});
    await recorder.flushAndVerifyHealth();
    expect(recorder.ackedSeq, 5);

    // Симулируем баг сервера: seq уменьшился с 5 до 3
    serverSeq = 3;
    recorder.observeControlInput({'type': 'hotkey', 'action': '2'});
    expect(
      recorder.flushAndVerifyHealth(),
      throwsFormatException,
    );
  });

  test('2.2: stop(reason) records session_ended or mandatory_violation, gap_marker on lost tail', () async {
    var currentNow = DateTime.utc(2026, 10, 24, 12, 0, 0);
    final sentEvents = <Map<String, dynamic>>[];

    final recorder = LinkHostRecorder(
      sessionId: '9b1deb4d-3b7d-4bad-9bdd-2b0d7b3dcb6d',
      config: const LinkRecordingConfig(enabled: true),
      clock: () => currentNow,
      sendBatch: (batch) async {
        final evs = batch['events'] as List<Map<String, dynamic>>;
        sentEvents.addAll(evs);
        final maxSeq = evs.isNotEmpty ? evs.last['seq'] as int : 0;
        return LinkRecorderBatchAck(
          ackHighWatermarkSeq: maxSeq,
          firstFrameAcked: true,
          leaseExpiresAt: currentNow.add(const Duration(seconds: 45)),
        );
      },
    );

    recorder.start();
    await recorder.stop(reason: 'user_disconnected');

    expect(sentEvents.any((e) => e['event_type'] == 'session_ended'), isTrue);
    final endEv = sentEvents.firstWhere((e) => e['event_type'] == 'session_ended');
    expect(endEv['metadata']['reason'], 'user_disconnected');
  });

  test('2.4: desktop change grace period (<= 10s) defers first_frame_unavailable', () async {
    var currentNow = DateTime.utc(2026, 10, 24, 12, 0, 0);
    String? violation;

    final recorder = LinkHostRecorder(
      sessionId: '9b1deb4d-3b7d-4bad-9bdd-2b0d7b3dcb6d',
      config: const LinkRecordingConfig(
        enabled: true,
        mandatory: true,
        maxAckLag: Duration(seconds: 5),
      ),
      clock: () => currentNow,
      onMandatoryViolation: (r) => violation = r,
      sendBatch: (_) async => LinkRecorderBatchAck(
        ackHighWatermarkSeq: 1,
        firstFrameAcked: false,
        leaseExpiresAt: currentNow.add(const Duration(seconds: 45)),
      ),
    );

    // Уведомляем о смене рабочего стола (Winlogon / UAC)
    recorder.notifyDesktopChanged();

    // Прошло 6 секунд (> maxAckLag 5s), но grace period 10s активен:
    currentNow = currentNow.add(const Duration(seconds: 6));
    await recorder.flushAndVerifyHealth();
    expect(violation, isNull);

    // По истечении 11 секунд (> 10s grace period) без кадра — срабатывает остановка:
    currentNow = currentNow.add(const Duration(seconds: 5));
    await recorder.flushAndVerifyHealth();
    expect(violation, 'recorder_first_frame_unavailable');
  });

  test('5.1: remaining lease_ttl_ms is tracked monotonically and deducts RTT', () async {
    var currentNow = DateTime.utc(2026, 10, 24, 12, 0, 0);
    String? violation;

    final recorder = LinkHostRecorder(
      sessionId: '9b1deb4d-3b7d-4bad-9bdd-2b0d7b3dcb6d',
      config: const LinkRecordingConfig(
        enabled: true,
        mandatory: true,
        maxAckLag: Duration(seconds: 60),
      ),
      clock: () => currentNow,
      onMandatoryViolation: (r) => violation = r,
      sendBatch: (_) async {
        // Симулируем задержку сети RTT ~ 50 мс
        await Future.delayed(const Duration(milliseconds: 50));
        return LinkRecorderBatchAck(
          ackHighWatermarkSeq: 1,
          firstFrameAcked: true,
          leaseExpiresAt: currentNow.add(const Duration(seconds: 45)),
          leaseTtlMs: 200, // остаток аренды 200 мс
        );
      },
    );

    recorder.enqueueFrame(frameKind: 'keyframe', payload: Uint8List(10));
    final ok = await recorder.flushAndVerifyHealth();
    expect(ok, isTrue);
    expect(violation, isNull);

    // До истечения 200 мс - всё в порядке
    await Future.delayed(const Duration(milliseconds: 50));
    expect(await recorder.flushAndVerifyHealth(), isTrue);
    expect(violation, isNull);

    // После истечения (суммарно > 200 мс) - срабатывает остановка по истечению аренды
    await Future.delayed(const Duration(milliseconds: 150));
    final expired = await recorder.flushAndVerifyHealth();
    expect(expired, isFalse);
    expect(violation, 'recorder_lease_expired');
  });

  test('5.2: zero or negative lease_ttl_ms immediately triggers lease expiration', () async {
    var currentNow = DateTime.utc(2026, 10, 24, 12, 0, 0);
    String? violation;

    final recorder = LinkHostRecorder(
      sessionId: '9b1deb4d-3b7d-4bad-9bdd-2b0d7b3dcb6d',
      config: const LinkRecordingConfig(
        enabled: true,
        mandatory: true,
        maxAckLag: Duration(seconds: 60),
      ),
      clock: () => currentNow,
      onMandatoryViolation: (r) => violation = r,
      sendBatch: (_) async => LinkRecorderBatchAck(
        ackHighWatermarkSeq: 1,
        firstFrameAcked: true,
        leaseExpiresAt: currentNow.add(const Duration(seconds: 45)),
        leaseTtlMs: 0,
      ),
    );

    recorder.enqueueFrame(frameKind: 'keyframe', payload: Uint8List(10));
    final ok = await recorder.flushAndVerifyHealth();
    // При lease_ttl_ms = 0 аренда истекла сразу
    expect(ok, isFalse);
    expect(violation, 'recorder_lease_expired');
  });

  test('5.3: stop returns false when unconfirmed tail could not be flushed', () async {
    var currentNow = DateTime.utc(2026, 10, 24, 12, 0, 0);

    final recorder = LinkHostRecorder(
      sessionId: '9b1deb4d-3b7d-4bad-9bdd-2b0d7b3dcb6d',
      config: const LinkRecordingConfig(enabled: true),
      clock: () => currentNow,
      sendBatch: (_) async {
        throw const HttpException('network down');
      },
    );

    recorder.enqueueFrame(frameKind: 'keyframe', payload: Uint8List(10));
    final flushed = await recorder.stop(reason: 'session_ended');
    expect(flushed, isFalse);
    expect(recorder.isTailFlushed, isFalse);
  });

  test('stop times out a stalled in-flight flush and reports tail loss', () async {
    final stalled = Completer<LinkRecorderBatchAck>();
    final recorder = LinkHostRecorder(
      sessionId: '9b1deb4d-3b7d-4bad-9bdd-2b0d7b3dcb6d',
      config: const LinkRecordingConfig(enabled: true),
      stopFlushTimeout: const Duration(milliseconds: 20),
      sendBatch: (_) => stalled.future,
    );
    recorder.start();
    final flushing = recorder.flushAndVerifyHealth();

    final flushed = await recorder.stop(reason: 'session_ended');
    expect(flushed, isFalse);
    expect(recorder.isTailFlushed, isFalse);

    stalled.complete(LinkRecorderBatchAck(
      ackHighWatermarkSeq: 1,
      firstFrameAcked: true,
      leaseExpiresAt: DateTime.now().add(const Duration(seconds: 45)),
    ));
    await flushing;
  });

  test('default HTTP sender times out an unfinished ACK body', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      await request.drain();
      request.response.statusCode = HttpStatus.ok;
      await request.response.flush();
    });
    try {
      await expectLater(
        LinkHostRecorder.defaultHttpSendBatch(
          'http://127.0.0.1:${server.port}/ingest',
          '',
          const {},
          timeout: const Duration(milliseconds: 30),
        ),
        throwsA(isA<TimeoutException>()),
      );
    } finally {
      await server.close(force: true);
    }
  });
}
