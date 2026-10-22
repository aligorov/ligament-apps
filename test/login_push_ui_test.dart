import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ligament_authenticator/api/client.dart';
import 'package:ligament_authenticator/screens/login_screen.dart';
import 'package:ligament_authenticator/services/auth_state.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeAuthState extends AuthState {
  bool loginCalled = false;
  bool shouldThrowSecondFactor = true;

  @override
  Future<void> login(String username, String password, [String? code]) async {
    loginCalled = true;
    if (shouldThrowSecondFactor) {
      throw ApiException(
        401,
        'second_factor_required',
        '',
        {
          'error': 'second_factor_required',
          'challenge_id': 'fake-ch-123',
          'claim_token': 'fake-token-456',
          'push_sent': true,
        },
      );
    }
  }

  @override
  Future<Map<String, dynamic>> loginClaim({
    required String challengeId,
    required String claimToken,
  }) async {
    return {'status': 'pending'};
  }
}

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

  testWidgets('LoginScreen shows push waiting card when push_sent is true in 2FA response', (tester) async {
    final fakeAuth = FakeAuthState();

    await tester.pumpWidget(
      ChangeNotifierProvider<AuthState>.value(
        value: fakeAuth,
        child: const MaterialApp(
          home: LoginScreen(serverConfig: {'server_name': 'Test Server'}),
        ),
      ),
    );

    // Enter username and password
    await tester.enterText(find.byType(TextField).at(0), 'alice');
    await tester.enterText(find.byType(TextField).at(1), 'password');

    // Tap login button
    await tester.tap(find.byType(ElevatedButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // Verify push waiting card appears
    expect(find.textContaining('Запрос подтверждения отправлен на телефон'), findsOneWidget);
    expect(find.textContaining('Или введите одноразовый код'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    // Verify back to password button resets state
    final backBtn = find.text('← Вернуться к вводу пароля');
    await tester.ensureVisible(backBtn);
    await tester.tap(backBtn);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.textContaining('Запрос подтверждения отправлен на телефон'), findsNothing);
    expect(find.byType(TextField), findsNWidgets(2)); // username and password fields restored
  });
}
