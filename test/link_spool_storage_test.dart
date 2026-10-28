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

  test('encrypts data-at-rest and rejects tampered files', () async {
    const sensitiveText = 'SUPER_SECRET_ADMIN_TOKEN_12345';
    await spool.writeBatch(1, {'secret': sensitiveText});

    final files = await spool.getPendingBatches();
    expect(files.length, 1);

    // 1. Verify file on disk does NOT contain plaintext sensitive text
    final rawBytes = await files.first.readAsBytes();
    final rawString = String.fromCharCodes(rawBytes);
    expect(rawString.contains(sensitiveText), isFalse);

    // 2. Legitimate read decrypts accurately
    final decrypted = await spool.readBatch(files.first);
    expect(decrypted?['secret'], sensitiveText);

    // 3. Modifying a byte in the encrypted spool triggers HMAC failure and returns null
    final tamperedBytes = List<int>.from(rawBytes);
    tamperedBytes[tamperedBytes.length - 1] ^= 0x01; // flip a bit
    await files.first.writeAsBytes(tamperedBytes);

    final tamperedResult = await spool.readBatch(files.first);
    expect(tamperedResult, isNull);
  });

  test('purgeOrphanedSpools deletes directories older than threshold', () async {
    final baseDir = await Directory.systemTemp.createTemp('spool_reaper_base_');
    try {
      final oldDir = Directory('${baseDir.path}/old_session')..createSync();
      final freshDir = Directory('${baseDir.path}/fresh_session')..createSync();

      // Run purge with 0ms maxAge to test reaper cleanup
      final purged = await LinkSpoolStorage.purgeOrphanedSpools(
        baseDir: baseDir,
        maxAge: Duration.zero,
      );
      expect(purged, 2);
      expect(oldDir.existsSync(), isFalse);
      expect(freshDir.existsSync(), isFalse);
    } finally {
      if (baseDir.existsSync()) {
        baseDir.deleteSync(recursive: true);
      }
    }
  });

  test('session key persists in directory and survives host crash/restart', () async {
    const originalText = 'RECOVERED_AFTER_CRASH_OR_REBOOT';
    await spool.writeBatch(1, {'message': originalText});

    final keyFile = File('${tempDir.path}/.session.key');
    expect(keyFile.existsSync(), isTrue);
    expect(keyFile.lengthSync(), 32);

    // Simulate process termination and new instance launching against existing spool dir
    final restartedSpool = LinkSpoolStorage(
      sessionId: 'test-session-123',
      storageDir: tempDir,
      maxSpoolBytes: 10 * 1024,
    );

    // Key was reloaded from file, not newly generated
    expect(restartedSpool.sessionKey, spool.sessionKey);

    final pending = await restartedSpool.getPendingBatches();
    expect(pending.length, 1);

    final decrypted = await restartedSpool.readBatch(pending.first);
    expect(decrypted?['message'], originalText);
  });

  test('disk safety floor prevents spool writes when free disk space is low', () async {
    final floorDir = Directory('${tempDir.path}/floor');
    final floorSpool = LinkSpoolStorage(
      sessionId: 'floor-session',
      storageDir: floorDir,
      minFreeDiskBytes: 500 * 1024 * 1024, // 500 MB required
      freeBytesChecker: () => 100 * 1024 * 1024, // Only 100 MB available
    );

    await expectLater(
      floorSpool.writeBatch(1, {'data': 'test'}),
      throwsA(
        isA<LinkSpoolQuotaExceededException>().having(
          (e) => e.message,
          'message',
          contains('Disk safety floor reached'),
        ),
      ),
    );

    final okDir = Directory('${tempDir.path}/ok');
    final okSpool = LinkSpoolStorage(
      sessionId: 'floor-session-ok',
      storageDir: okDir,
      minFreeDiskBytes: 500 * 1024 * 1024,
      freeBytesChecker: () => 10 * 1024 * 1024 * 1024, // 10 GB available
    );

    await okSpool.writeBatch(1, {'data': 'safe_payload'});
    expect(await okSpool.hasPending(), isTrue);
  });
}
