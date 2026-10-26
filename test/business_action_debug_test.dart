import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ligament_authenticator/api/client.dart';
import 'package:ligament_authenticator/screens/login_screen.dart';
import 'package:ligament_authenticator/screens/settings_screen.dart';
import 'package:ligament_authenticator/services/auth_state.dart';
import 'package:ligament_authenticator/services/debug_log_service.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _SettingsAuth extends AuthState {
  final pending = Completer<void>();
  bool fail = false;
  List<Map<String, dynamic>> deliveries = [];

  @override
  Future<List<Map<String, dynamic>>> testNotificationDelivery() async =>
      deliveries;

  @override
  Future<void> updateNotificationSettings({
    required bool loginSuccess,
    required bool loginDenied,
    required bool notifyTG,
    required bool notifyEmail,
  }) async {
    await pending.future;
    if (fail) {
      throw PlatformException(
        code: 'notification_save_failed',
        message: 'password-secret user@example.invalid',
        details: {'token': 'claim-secret'},
      );
    }
  }
}

class _ClaimAuth extends AuthState {
  @override
  Future<void> login(String username, String password, [String? code]) async {
    throw ApiException(401, 'second_factor_required', '', {
      'challenge_id': 'private-challenge',
      'claim_token': 'private-claim',
      'push_sent': true,
    });
  }

  @override
  Future<Map<String, dynamic>> loginClaim(
          {required String challengeId, required String claimToken}) async =>
      {
        'token': 'private-response-token',
        'user': {'username': 'private-username'},
      };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/business_actions');
  final entries = <Map<String, Object?>>[];

  setUp(() {
    entries.clear();
    SharedPreferences.setMockInitialValues({});
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'write') {
        entries.add(Map<String, Object?>.from(call.arguments as Map));
        return true;
      }
      return {'enabled': true, 'path': r'C:\Logs\app-debug.log'};
    });
    messenger.setMockMethodCallHandler(
      const MethodChannel('xyz.luan/audioplayers'),
      (call) async => call.method == 'create' ? 'test-player' : null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('xyz.luan/audioplayers.global'),
      (call) async => null,
    );
  });

  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final name in [
      'test/business_actions',
      'xyz.luan/audioplayers',
      'xyz.luan/audioplayers.global',
    ]) {
      messenger.setMockMethodCallHandler(MethodChannel(name), null);
    }
  });

  Future<void> mount(
      WidgetTester tester, _SettingsAuth auth, DebugLogService logs) async {
    await logs.initialize();
    await tester.pumpWidget(ChangeNotifierProvider<AuthState>.value(
      value: auth,
      child: MaterialApp(home: SettingsScreen(debugLogs: logs)),
    ));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Успешный вход (QR, Passkey, Push)'),
      150,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
  }

  Finder notificationSwitch() => find.descendant(
        of: find
            .ancestor(
              of: find.text('Успешный вход (QR, Passkey, Push)'),
              matching: find.byType(Row),
            )
            .first,
        matching: find.byType(Switch),
      );

  testWidgets('notification intent is recorded before the awaited outcome',
      (tester) async {
    final auth = _SettingsAuth();
    final logs = DebugLogService(channel: channel, nativeWindows: true);
    await mount(tester, auth, logs);
    await tester.tap(notificationSwitch());
    await tester.pump();
    await logs.flush();
    expect(entries.where((e) => e['event'] == 'ui.settings.action.started'),
        hasLength(1));
    expect(entries.where((e) => e['event'] == 'ui.settings.action.completed'),
        isEmpty);
    expect(
        entries.first['context'], contains('operation=notify_login_success'));
    expect(entries.first['context'], contains('state=disabled'));

    auth.pending.complete();
    await tester.pumpAndSettle();
    await logs.flush();
    final completed = entries
        .singleWhere((e) => e['event'] == 'ui.settings.action.completed');
    expect(completed['context'], contains('duration_ms='));
    expect(completed['context'], contains('result=future_returned'));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    logs.dispose();
  });

  testWidgets('token response without committed authentication is cancellation',
      (tester) async {
    final auth = _ClaimAuth();
    final logs = DebugLogService(channel: channel, nativeWindows: true);
    await logs.initialize();
    await tester.pumpWidget(ChangeNotifierProvider<AuthState>.value(
      value: auth,
      child: MaterialApp(
          home: LoginScreen(serverConfig: const {}, debugLogs: logs)),
    ));
    await tester.enterText(find.byType(TextField).at(0), 'private-username');
    await tester.enterText(find.byType(TextField).at(1), 'private-password');
    await tester.tap(find.byType(ElevatedButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1600));
    await tester.pump();
    await logs.flush();
    final cancelled = entries
        .singleWhere((entry) => entry['event'] == 'ui.login.claim.cancelled');
    expect(cancelled['context'], contains('result=superseded'));
    expect(entries.toString(), isNot(contains('result=authenticated')));
    for (final secret in [
      'private-response-token',
      'private-username',
      'private-password',
      'private-claim'
    ]) {
      expect(entries.toString(), isNot(contains(secret)));
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    logs.dispose();
  });

  testWidgets('empty delivery result is never reported as delivered',
      (tester) async {
    final auth = _SettingsAuth();
    final logs = DebugLogService(channel: channel, nativeWindows: true);
    await mount(tester, auth, logs);
    final button = find.textContaining('Проверить реальную доставку');
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pump();
    await tester.pumpAndSettle();
    await logs.flush();
    final result = entries.singleWhere(
        (entry) => entry['event'] == 'ui.settings.test_delivery.results');
    expect(result['context'], contains('count=0'));
    expect(result['context'], contains('result=no_deliveries'));
    expect(entries.toString(), isNot(contains('all_reported_success')));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    logs.dispose();
  });

  testWidgets('notification failure records safe error metadata, not details',
      (tester) async {
    final auth = _SettingsAuth()..fail = true;
    final logs = DebugLogService(channel: channel, nativeWindows: true);
    await mount(tester, auth, logs);
    await tester.tap(notificationSwitch());
    auth.pending.complete();
    await tester.pumpAndSettle();
    await logs.flush();
    final failure =
        entries.singleWhere((e) => e['event'] == 'ui.settings.action.failed');
    expect(failure['error_type'], 'PlatformException');
    expect(failure['error_code'], 'notification_save_failed');
    expect(failure['context'], contains('duration_ms='));
    expect(entries.where((e) => e['event'] == 'ui.settings.action.completed'),
        isEmpty);
    final serialized = entries.toString();
    for (final secret in [
      'password-secret',
      'user@example.invalid',
      'claim-secret'
    ]) {
      expect(serialized, isNot(contains(secret)));
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    logs.dispose();
  });
}
