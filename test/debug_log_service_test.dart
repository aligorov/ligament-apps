import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ligament_authenticator/api/client.dart';
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
    logs.record('auth.storage.failed',
        error: PlatformException(
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

  test('context keeps diagnostic facts and rejects payloads and secrets',
      () async {
    final logs = localService();
    await logs.setEnabled(true);
    logs.record('http.response', fields: {
      'request_id': 17,
      'method': 'POST',
      'route': '/api/v1/app/link/sessions/{id}/signal',
      'server': '2fa.example.test',
      'http_status': 403,
      'duration_ms': 250,
      'session_id': '10000000-0000-4000-8000-000000000001',
      'reason': 'access_denied',
      'connected': false,
      'token': 'private-token',
      'password': 'private-password',
      'sdp': 'private-sdp',
      'message': 'private-input',
      'query': 'token=private-token',
    });
    await logs.flush();
    final output = await File(logs.path!).readAsString();
    expect(output, contains('request_id=17'));
    expect(output, contains('http_status=403'));
    expect(output, contains('duration_ms=250'));
    expect(output, contains('reason=access_denied'));
    expect(output, contains('connected=false'));
    expect(output, contains('route=/api/v1/app/link/sessions/{id}/signal'));
    for (final secret in [
      'private-token',
      'private-password',
      'private-sdp',
      'private-input'
    ]) {
      expect(output, isNot(contains(secret)));
    }
    expect(
        DebugLogService.safeFields({
          'reason': 'ab' * 32,
          'route': '/api/v1/app/login?token=secret',
          'server': 'user:secret@host',
          'session_id': 'not-a-uuid',
          'duration_ms': double.infinity,
        }),
        isEmpty);
  });

  test('native channel receives structured context without raw payloads',
      () async {
    final entries = <Map<String, dynamic>>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getState') return {'enabled': true, 'path': 'log'};
      if (call.method == 'write') {
        entries.add(Map<String, dynamic>.from(call.arguments as Map));
      }
      return true;
    });
    final logs = DebugLogService(nativeWindows: true, channel: channel);
    await logs.initialize();
    logs.record('operator.terminated', fields: {
      'attempt': 2,
      'origin': 'host_answer',
      'reason': 'host_media_failed',
      'frame_ready': false,
      'clipboard': 'secret',
    });
    await logs.flush();
    expect(entries.single['context'],
        'attempt=2 origin=host_answer reason=host_media_failed frame_ready=false');
    expect(entries.single.toString(), isNot(contains('secret')));
  });

  test('remote error labels are fixed protocol values, not arbitrary text',
      () async {
    final logs = localService();
    await logs.setEnabled(true);
    logs.record('http.rejected',
        error: ApiException(403, 'private-error-secret'));
    logs.record('http.rejected', error: ApiException(403, 'access_denied'));
    logs.record('operator.session.terminated', fields: {
      'reason': DebugLogService.protocolLabel('recorder_queue_overflow'),
    });
    await logs.flush();
    final text = await File(logs.path!).readAsString();
    expect(text, contains('error_code=http_403.unknown'));
    expect(text, contains('error_code=http_403.access_denied'));
    expect(text, contains('reason=recorder_queue_overflow'));
    expect(text, isNot(contains('private-error-secret')));
    for (final value in [
      null,
      284917,
      '284917',
      'Bearer-private-token',
      'private_error_secret'
    ]) {
      expect(DebugLogService.protocolLabel(value), 'unknown');
    }
  });

  test('slow native writer has a bounded queue and reports overflow', () async {
    final blocked = Completer<void>();
    final entries = <Map<String, dynamic>>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getState') return {'enabled': true, 'path': 'log'};
      if (call.method == 'write') {
        if (entries.isEmpty) await blocked.future;
        entries.add(Map<String, dynamic>.from(call.arguments as Map));
      }
      return true;
    });
    final logs = DebugLogService(nativeWindows: true, channel: channel);
    await logs.initialize();
    for (var i = 0; i < DebugLogService.maxPendingEntries + 37; i++) {
      logs.record('ui.action', fields: {'count': i});
    }
    blocked.complete();
    await logs.flush();
    expect(entries.where((entry) => entry['event'] == 'ui.action').length,
        DebugLogService.maxPendingEntries);
    final dropped =
        entries.singleWhere((entry) => entry['event'] == 'debug.queue.dropped');
    expect(dropped['context'], 'count=37');
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

  test('native Windows toggle is authoritative and preserves failed state',
      () async {
    var enabled = true;
    var rejectWrite = false;
    final events = <Map<String, dynamic>>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'getState':
          return {'enabled': enabled, 'path': 'app-debug.log'};
        case 'setEnabled':
          if (rejectWrite) {
            throw PlatformException(code: 'registry_write_failed');
          }
          enabled = call.arguments as bool;
          return {'enabled': enabled, 'path': 'app-debug.log'};
        case 'write':
          if (enabled) {
            events.add(Map<String, dynamic>.from(call.arguments as Map));
          }
          return enabled;
      }
      return null;
    });
    final logs = DebugLogService(nativeWindows: true, channel: channel);
    await logs.initialize();
    expect(logs.enabled, isTrue);
    logs.record('native.write',
        error: const SocketException('secret',
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

  testWidgets('uninitialized Windows logger does not leave a widget timer',
      (tester) async {
    final pending = Completer<bool>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'write') return pending.future;
      return {'enabled': false, 'path': 'log'};
    });
    final logs = DebugLogService(nativeWindows: true, channel: channel);
    await tester.pumpWidget(MaterialApp(
        home: TextButton(
      onPressed: () => logs.record('ui.test.action'),
      child: const Text('Action'),
    )));
    await tester.tap(find.text('Action'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    expect(logs.initialized, isFalse);
  });

  testWidgets(
      'initialized Windows writer times out and continues while cached off',
      (tester) async {
    final pending = Completer<bool>();
    final events = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getState') return {'enabled': false, 'path': 'log'};
      if (call.method == 'write') {
        events.add((call.arguments as Map)['event'] as String);
        if (events.length == 1) return pending.future;
      }
      return true;
    });
    final logs = DebugLogService(nativeWindows: true, channel: channel);
    await logs.initialize();
    expect(logs.enabled, isFalse);
    logs.record('native.first');
    logs.record('native.second');
    await tester.pump();
    expect(events, ['native.first']);
    await tester.pump(const Duration(milliseconds: 1100));
    await logs.flush();
    expect(events, ['native.first', 'native.second']);
    pending.complete(false);
    await tester.pump();
  });

  test('native worker responds to changes made by another process', () async {
    var enabled = false;
    final events = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getState') {
        return {'enabled': false, 'path': 'link-debug.log'};
      }
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
