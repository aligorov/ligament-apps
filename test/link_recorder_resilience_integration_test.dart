import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ligament_authenticator/services/link_host_recorder.dart';
import 'package:ligament_authenticator/services/link_spool_storage.dart';

List<int> _extractSeqs(Map<String, dynamic> batch) => [
      for (final frame in (batch['frames'] as List? ?? []))
        frame['seq'] as int,
      for (final event in (batch['events'] as List? ?? []))
        event['seq'] as int,
    ]..sort();

LinkRecorderBatchAck _makeAck(Map<String, dynamic> batch) =>
    LinkRecorderBatchAck(
      ackHighWatermarkSeq: _extractSeqs(batch)
          .fold<int>(0, (high, seq) => seq > high ? seq : high),
      firstFrameAcked: true,
      leaseExpiresAt: DateTime.now().add(const Duration(seconds: 45)),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
      'End-to-End: network stall causes spooling to disk; session continues and drains spool on network recovery',
      () async {
    final violations = <String>[];
    final uploadedBatches = <Map<String, dynamic>>[];
    var networkAvailable = false;

    final tempDir = await Directory.systemTemp.createTemp('e2e_spool_');
    final spool = LinkSpoolStorage(
      sessionId: '550e8400-e29b-41d4-a716-446655440000',
      storageDir: tempDir,
    );

    try {
      final recorder = LinkHostRecorder(
        sessionId: '550e8400-e29b-41d4-a716-446655440000',
        config: const LinkRecordingConfig(
          enabled: true,
          mandatory: true,
          failurePolicy: 'resilient',
          maxQueueBytes: 4096, // Compact RAM queue to test spilling
          maxAckLag: Duration(seconds: 15),
        ),
        spool: spool,
        onMandatoryViolation: violations.add,
        sendBatch: (batch) async {
          if (!networkAvailable) {
            throw const SocketException('Connection refused / network lag');
          }
          uploadedBatches
              .add(jsonDecode(jsonEncode(batch)) as Map<String, dynamic>);
          return _makeAck(batch);
        },
      );

      recorder.start();

      // 1. Generate frames and inputs while network is DOWN
      for (var i = 0; i < 400; i++) {
        recorder.observeControlInput({'type': 'wheel', 'deltaY': i});
        recorder.enqueueFrame(
          frameKind: 'activity',
          payload: Uint8List.fromList(List.filled(30, i % 256)),
        );
      }

      // Try flushing while network is down - should not terminate session
      final flushResultDuringStall = await recorder.flushAndVerifyHealth();
      expect(flushResultDuringStall, isTrue,
          reason: 'flush in resilient mode returns true even with network lag');
      expect(violations, isEmpty,
          reason: 'session must NOT be rejected in resilient mode');

      // Verify that data was written to disk spool
      expect(await spool.hasPending(), isTrue,
          reason: 'spool must hold chunks on disk');
      final spooledFiles = await spool.getPendingBatches();
      expect(spooledFiles.length, greaterThan(0));

      // 2. RESTORE NETWORK
      networkAvailable = true;

      // 3. Trigger flush cycle - it must drain disk spool first, then live queue
      final flushResultAfterRecovery = await recorder.flushAndVerifyHealth();
      expect(flushResultAfterRecovery, isTrue);
      expect(uploadedBatches.length, greaterThan(0),
          reason: 'spooled chunks must be uploaded to server');

      // Verify spool has drained on disk
      expect(await spool.hasPending(), isFalse,
          reason: 'spool files must be deleted after server ACK');

      // 4. Clean stop
      final stopSuccess = await recorder.stop(reason: 'session_ended');
      expect(stopSuccess, isTrue);
      expect(violations, isEmpty);
    } finally {
      await spool.clear();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    }
  });
}
