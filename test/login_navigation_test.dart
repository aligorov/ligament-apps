import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ligament_authenticator/screens/connect_screen.dart';
import 'package:ligament_authenticator/screens/login_screen.dart';
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

  testWidgets('LoginScreen leading back button returns to ConnectScreen when no pop history', (tester) async {
    final authState = AuthState();

    await tester.pumpWidget(
      ChangeNotifierProvider<AuthState>.value(
        value: authState,
        child: const MaterialApp(
          home: LoginScreen(serverConfig: {'server_name': 'Test Server'}),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(LoginScreen), findsOneWidget);
    expect(find.byType(ConnectScreen), findsNothing);

    // Verify back icon exists
    final backBtn = find.byTooltip('Сменить сервер');
    expect(backBtn, findsOneWidget);

    // Tap back button
    await tester.tap(backBtn);
    await tester.pumpAndSettle();

    // Must navigate to ConnectScreen, NOT pop into an empty blank screen
    expect(find.byType(ConnectScreen), findsOneWidget);
    expect(find.byType(LoginScreen), findsNothing);
  });

  testWidgets('LoginScreen leading back button pops route if there is history', (tester) async {
    final authState = AuthState();

    await tester.pumpWidget(
      ChangeNotifierProvider<AuthState>.value(
        value: authState,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) => ElevatedButton(
                onPressed: () => Navigator.of(ctx).push(
                  MaterialPageRoute(
                    builder: (_) => const LoginScreen(serverConfig: {'server_name': 'Test Server'}),
                  ),
                ),
                child: const Text('Open Login'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Push LoginScreen
    await tester.tap(find.text('Open Login'));
    await tester.pumpAndSettle();

    expect(find.byType(LoginScreen), findsOneWidget);

    // Tooltip should be "Назад" because canPop is true
    final backBtn = find.byTooltip('Назад');
    expect(backBtn, findsOneWidget);

    await tester.tap(backBtn);
    await tester.pumpAndSettle();

    expect(find.byType(LoginScreen), findsNothing);
    expect(find.text('Open Login'), findsOneWidget);
  });
}
