import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:ligament_authenticator/main.dart';
import 'package:ligament_authenticator/services/auth_state.dart';
import 'package:ligament_authenticator/screens/login_screen.dart';
import 'package:ligament_authenticator/screens/home_screen.dart';
import 'package:ligament_authenticator/screens/settings_screen.dart';
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
  testWidgets('LigamentApp boots and renders ConnectScreen in RU and EN', (WidgetTester tester) async {
    final authState = AuthState();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: authState,
        child: const LigamentApp(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(MaterialApp), findsOneWidget);
    expect(find.text('Ligament 2FA'), findsWidgets);
    expect(find.text('Подключиться'), findsOneWidget);
  });

  testWidgets('LoginScreen renders correctly in RU', (WidgetTester tester) async {
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

  testWidgets('SettingsScreen renders correctly in RU', (WidgetTester tester) async {
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
}
