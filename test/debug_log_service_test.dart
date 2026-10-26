import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ligament_authenticator/services/debug_log_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.ligament/diagnostics');
  late Directory directory;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('ligament-debug-test-');
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await directory.delete(recursive: true);
  });

  DebugLogService localService() => DebugLogService(
        nativeWindows: false,
        directory: () async => directory,
      );

  test('disabled by default and does not create a log', () async {
    final logs = localService();
    await logs.initialize();
    logs.record('app.bootstrap.begin');
    await logs.flush();

    expect(logs.enabled, isFalse);
    expect(await directory.list().isEmpty, isTrue);
  });

  test('toggle persists and disabling stops writes', () async {
    final logs = localService();
    await logs.initialize();
    await logs.setEnabled(true);
    logs.record('app.bootstrap.ready');
    await logs.flush();
    final file = File(logs.path!);
    expect(await file.readAsString(), contains('app.bootstrap.ready'));

    final restored = localService();
    await restored.initialize();
    expect(restored.enabled, isTrue);

    await logs.setEnabled(false);
    final before = await file.readAsString();
    logs.record('must.not.be.written');
    await logs.flush();
    expect(await file.readAsString(), before);
    expect(before, contains('debug.disabled'));

    final disabled = localService();
    await disabled.initialize();
    expect(disabled.enabled, isFalse);
  });

  test('logs only safe error fields and excludes exception messages', () async {
    final logs = localService();
    await logs.setEnabled(true);
    logs.record('auth.storage.failed', error: PlatformException(
      code: 'storage_unavailable',
      message: 'Bearer secret-token password=secret typed-text',
      details: {'token': 'secret-token'},
    ));
    logs.record('raw\npassword=secret');
    await logs.flush();

    final content = await File(logs.path!).readAsString();
    expect(content, contains('error_type=PlatformException'));
    expect(content, contains('error_code=storage_unavailable'));
    expect(content, isNot(contains('secret-token')));
    expect(content, isNot(contains('password=')));
    expect(content, isNot(contains('typed-text')));
  });

  test('rotates current file and keeps one backup', () async {
    final logs = localService();
    await logs.setEnabled(true);
    await logs.flush();
    final file = File(logs.path!);
    await file.writeAsString('x' * DebugLogService.maxFileBytes);
    logs.record('rotation.first');
    await logs.flush();
    expect(await file.length(), lessThan(DebugLogService.maxFileBytes));
    expect(await File('${file.path}.1').length(), DebugLogService.maxFileBytes);

    await file.writeAsString('y' * DebugLogService.maxFileBytes);
    logs.record('rotation.second');
    await logs.flush();
    expect(await File('${file.path}.1').readAsString(), startsWith('y'));
    expect(await File('${file.path}.2').exists(), isFalse);
  });

  test('native Windows toggle is authoritative and preserves failed state', () async {
    var enabled = true;
    var rejectWrite = false;
    final events = <Map<String, dynamic>>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'getState':
          return {'enabled': enabled, 'path': 'app-debug.log'};
        case 'setEnabled':
          if (rejectWrite) throw PlatformException(code: 'registry_write_failed');
          enabled = call.arguments as bool;
          return {'enabled': enabled, 'path': 'app-debug.log'};
        case 'write':
          if (enabled) events.add(Map<String, dynamic>.from(call.arguments as Map));
          return enabled;
      }
      return null;
    });
    final logs = DebugLogService(nativeWindows: true, channel: channel);
    await logs.initialize();
    expect(logs.enabled, isTrue);
    logs.record('native.write', error: const SocketException('secret',
        osError: OSError('private error', 5)));
    await logs.flush();
    expect(events.single['os_error'], 5);
    expect(events.single.containsKey('message'), isFalse);

    await logs.setEnabled(false);
    logs.record('native.disabled');
    await logs.flush();
    expect(events.length, 1);
    rejectWrite = true;
    await expectLater(logs.setEnabled(true), throwsA(isA<PlatformException>()));
    expect(logs.enabled, isFalse);
  });

  test('native worker responds to changes made by another process', () async {
    var enabled = false;
    final events = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getState') return {'enabled': false, 'path': 'link-debug.log'};
      if (call.method == 'write' && enabled) {
        events.add((call.arguments as Map)['event'] as String);
      }
      return enabled;
    });
    final logs = DebugLogService(nativeWindows: true, channel: channel);
    await logs.initialize();
    enabled = true;
    logs.record('link.session.ready');
    await logs.flush();
    expect(events, ['link.session.ready']);
    enabled = false;
    logs.record('link.session.closed');
    await logs.flush();
    expect(events.length, 1);
  });
}
