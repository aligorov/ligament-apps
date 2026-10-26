import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ligament_authenticator/services/link_spool_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late LinkSpoolStorage spool;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('link_spool_test_');
    spool = LinkSpoolStorage(
      sessionId: 'test-session-123',
      storageDir: tempDir,
      maxSpoolBytes: 10 * 1024, // 10 KB quota for testing
    );
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('writes batch atomically and lists pending in sequential order', () async {
    expect(await spool.hasPending(), isFalse);
    expect(spool.currentSpoolBytes, 0);

    final batch1 = {'seq': 1, 'data': 'payload_1'};
    final batch2 = {'seq': 2, 'data': 'payload_2'};

    await spool.writeBatch(1, batch1);
    await spool.writeBatch(2, batch2);

    expect(await spool.hasPending(), isTrue);
    expect(spool.currentSpoolBytes, greaterThan(0));

    final pending = await spool.getPendingBatches();
    expect(pending.length, 2);

    final read1 = await spool.readBatch(pending[0]);
    final read2 = await spool.readBatch(pending[1]);

    expect(read1?['seq'], 1);
    expect(read2?['seq'], 2);

    await spool.removeBatch(pending[0]);
    final remaining = await spool.getPendingBatches();
    expect(remaining.length, 1);
    expect(remaining[0].path, pending[1].path);

    await spool.clear();
    expect(await spool.hasPending(), isFalse);
  });

  test('enforces maxSpoolBytes quota and throws LinkSpoolQuotaExceededException', () async {
    final largePayload = {'data': 'X' * 6000};
    await spool.writeBatch(1, largePayload);

    // Second batch exceeds the 10 KB quota
    expect(
      () => spool.writeBatch(2, largePayload),
      throwsA(isA<LinkSpoolQuotaExceededException>()),
    );
  });
}
