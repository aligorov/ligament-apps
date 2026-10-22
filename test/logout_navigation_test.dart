import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ligament_authenticator/screens/connect_screen.dart';
import 'package:ligament_authenticator/screens/settings_screen.dart';
import 'package:ligament_authenticator/services/auth_state.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('xyz.luan/audioplayers'),
      (call) async => call.method == 'create' ? 'test-player' : null,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('xyz.luan/audioplayers.global'),
      (call) async => null,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => null,
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('xyz.luan/audioplayers'), null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('xyz.luan/audioplayers.global'), null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'), null);
  });

  testWidgets('SettingsScreen logout button shows confirmation dialog and navigates to ConnectScreen on confirm', (tester) async {
    final authState = AuthState();
    authState.token = 'dummy-token';
    authState.currentUser = {'username': 'testuser', 'display_name': 'Test User'};

    await tester.pumpWidget(
      ChangeNotifierProvider<AuthState>.value(
        value: authState,
        child: const MaterialApp(
          locale: Locale('ru'),
          supportedLocales: [Locale('ru'), Locale('en')],
          localizationsDelegates: [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: SettingsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(SettingsScreen), findsOneWidget);

    // Scroll to the logout button
    final logoutBtn = find.byIcon(Icons.logout);
    await tester.scrollUntilVisible(
      logoutBtn,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();

    expect(logoutBtn, findsOneWidget);

    // Tap logout button
    await tester.tap(logoutBtn);
    await tester.pumpAndSettle();

    // Confirmation dialog should appear
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Вы действительно хотите выйти из учетной записи? Для повторного входа потребуется авторизация.'), findsOneWidget);

    // Cancel first
    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();

    // Dialog closed, still on SettingsScreen, still logged in
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(authState.isLoggedIn, isTrue);

    // Tap logout button again
    await tester.tap(logoutBtn);
    await tester.pumpAndSettle();

    // Tap confirm button in dialog (the one inside AlertDialog actions)
    final confirmBtn = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.text('Выйти из учетной записи'),
    );
    expect(confirmBtn, findsOneWidget);
    await tester.tap(confirmBtn);
    await tester.pumpAndSettle();

    // User should now be logged out and on ConnectScreen
    expect(authState.isLoggedIn, isFalse);
    expect(find.byType(ConnectScreen), findsOneWidget);
    expect(find.byType(SettingsScreen), findsNothing);
  });
}
