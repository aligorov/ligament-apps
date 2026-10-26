import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:ligament_authenticator/main.dart';
import 'package:ligament_authenticator/services/auth_state.dart';
import 'package:ligament_authenticator/screens/login_screen.dart';
import 'package:ligament_authenticator/screens/settings_screen.dart';
import 'package:ligament_authenticator/widgets/app_update_banner.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

Widget createTestApp(Widget child, AuthState auth) {
  return ChangeNotifierProvider.value(
    value: auth,
    child: MaterialApp(
      locale: auth.locale,
      supportedLocales: const [Locale('ru'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: child,
    ),
  );
}

void main() {
  testWidgets('LigamentApp boots and renders ConnectScreen in RU and EN',
      (WidgetTester tester) async {
    final semantics = tester.ensureSemantics();
    try {
      final authState = AuthState();
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: authState,
          child: const LigamentApp(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(MaterialApp), findsOneWidget);
      expect(find.bySemanticsLabel('Ligament 2FA'), findsWidgets);
      expect(find.text('Подключиться'), findsOneWidget);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('LoginScreen renders correctly in RU',
      (WidgetTester tester) async {
    final authState = AuthState();
    await tester.pumpWidget(
      createTestApp(
        const LoginScreen(serverConfig: {'allow_direct_login': true}),
        authState,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Войти в аккаунт'), findsOneWidget);
  });

  testWidgets('SettingsScreen renders correctly in RU',
      (WidgetTester tester) async {
    final authState = AuthState();
    await tester.pumpWidget(
      createTestApp(
        const SettingsScreen(),
        authState,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);
  });

  testWidgets('AppUpdateBanner shows version and opens branded URL',
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
    await tester.binding.setSurfaceSize(const Size(320, 160));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final authState = AuthState();
    await tester.pumpWidget(
      createTestApp(
        Scaffold(
          appBar: AppBar(
            bottom: const PreferredSize(
              preferredSize: Size.fromHeight(36),
              child: AppUpdateBanner(
                latestVersion: '1.1.130+156',
                releaseUrl: 'https://apps.example.corp/app.msi',
              ),
            ),
          ),
        ),
        authState,
      ),
    );

    expect(find.text('Доступна новая версия v1.1.130'), findsOneWidget);
    expect(find.text('Обновить'), findsOneWidget);
    expect(find.textContaining('+156'), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Обновить'));
    await tester.pump();
    expect(calls, hasLength(1));
    expect(calls.single.method, 'launch');
    final arguments = calls.single.arguments as Map<dynamic, dynamic>;
    expect(arguments['url'], 'https://apps.example.corp/app.msi');
  });
}
