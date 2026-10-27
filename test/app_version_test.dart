import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ligament_authenticator/app_version.dart';
import 'package:ligament_authenticator/widgets/app_update_dialog.dart';

void main() {
  test('formatAppVersion hides build metadata and keeps one v prefix', () {
    expect(formatAppVersion('1.1.130+156'), 'v1.1.130');
    expect(formatAppVersion('v1.1.130'), 'v1.1.130');
    expect(formatAppVersion(' 1.1.130+156 '), 'v1.1.130');
  });

  test('update comparison ignores build metadata', () {
    expect(isAppUpdateAvailable('1.1.130+155', 'v1.1.130+156'), isFalse);
    expect(isAppUpdateAvailable('1.1.129+155', 'v1.1.130'), isTrue);
    expect(isAppUpdateAvailable('v1.1.130', '1.1.131+157'), isTrue);
    expect(isAppUpdateAvailable('1.1.131+156', 'v1.1.130'), isFalse);
  });

  test('update comparison is numeric and rejects invalid versions', () {
    expect(isAppUpdateAvailable('1.1.99+100', 'v1.1.130'), isTrue);
    expect(isAppUpdateAvailable('dev', 'v1.1.130'), isFalse);
    expect(isAppUpdateAvailable('1.1.130', 'latest'), isFalse);
    expect(
      isAppUpdateAvailable('999999999999999999999999.1.1', 'v1.1.130'),
      isFalse,
    );
  });

  test('kAppVersion fallback is set to current release', () {
    expect(kAppVersion, '1.1.152+178');
  });

  testWidgets('AppUpdateDialog renders versions and launches download url',
      (WidgetTester tester) async {
    const channel = MethodChannel('plugins.flutter.io/url_launcher');
    final calls = <MethodCall>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return true;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: AppUpdateDialog(
            latestVersion: '1.1.145+171',
            releaseUrl: 'https://github.com/aligorov/ligament-apps/releases/latest',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Доступно обновление Ligament 2FA'), findsOneWidget);
    expect(find.text('v1.1.145'), findsOneWidget);
    expect(find.text('Скачать обновление'), findsOneWidget);

    await tester.tap(find.text('Скачать обновление'));
    await tester.pumpAndSettle();

    expect(calls, isNotEmpty);
    expect(calls.single.method, 'launch');
  });
}
