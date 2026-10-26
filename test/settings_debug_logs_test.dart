import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ligament_authenticator/screens/settings_screen.dart';
import 'package:ligament_authenticator/services/auth_state.dart';
import 'package:ligament_authenticator/services/debug_log_service.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.ligament/diagnostics');
  var enabled = false;
  var failSave = false;

  setUp(() {
    enabled = false;
    failSave = false;
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'setEnabled') {
        if (failSave) throw PlatformException(code: 'registry_write_failed');
        enabled = call.arguments as bool;
      }
      return {'enabled': enabled, 'path': r'C:\Logs\app-debug.log'};
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('xyz.luan/audioplayers'),
            (call) async => call.method == 'create' ? 'player' : null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('xyz.luan/audioplayers.global'),
            (call) async => null);
  });

  tearDown(() {
    for (final name in ['com.ligament/diagnostics', 'xyz.luan/audioplayers',
      'xyz.luan/audioplayers.global']) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(name), null);
    }
  });

  Future<void> mount(WidgetTester tester, DebugLogService logs) async {
    final auth = AuthState();
    await tester.pumpWidget(ChangeNotifierProvider<AuthState>.value(
      value: auth,
      child: MaterialApp(
        locale: const Locale('ru'),
        supportedLocales: const [Locale('ru'), Locale('en')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: SettingsScreen(debugLogs: logs),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Debug-логи'), 200,
        scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
  }

  Finder debugSwitch() => find.descendant(
        of: find.ancestor(of: find.text('Debug-логи'), matching: find.byType(Row)).first,
        matching: find.byType(Switch),
      );

  testWidgets('settings debug toggle enables, persists and disables logging', (tester) async {
    final logs = DebugLogService(nativeWindows: true, channel: channel);
    await mount(tester, logs);
    expect(tester.widget<Switch>(debugSwitch()).value, isFalse);

    await tester.tap(debugSwitch());
    await tester.pumpAndSettle();
    expect(enabled, isTrue);
    expect(tester.widget<Switch>(debugSwitch()).value, isTrue);
    expect(find.text(r'C:\Logs\app-debug.log'), findsOneWidget);

    final restarted = DebugLogService(nativeWindows: true, channel: channel);
    await restarted.initialize();
    expect(restarted.enabled, isTrue);

    await tester.tap(debugSwitch());
    await tester.pumpAndSettle();
    expect(enabled, isFalse);
    expect(logs.enabled, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings reports failed save without enabling logging', (tester) async {
    final logs = DebugLogService(nativeWindows: true, channel: channel);
    await mount(tester, logs);
    failSave = true;
    await tester.tap(debugSwitch());
    await tester.pumpAndSettle();

    expect(enabled, isFalse);
    expect(logs.enabled, isFalse);
    expect(find.text('Не удалось сохранить настройку debug-логов.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
