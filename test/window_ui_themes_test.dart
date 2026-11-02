import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ligament_authenticator/services/auth_state.dart';
import 'package:ligament_authenticator/widgets/window_caption_controls.dart';
import 'package:ligament_authenticator/widgets/neural_mesh_background.dart';
import 'package:ligament_authenticator/screens/settings_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('xyz.luan/audioplayers'), (_) async => null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('xyz.luan/audioplayers.global'),
            (_) async => null);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('xyz.luan/audioplayers'), null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('xyz.luan/audioplayers.global'), null);
  });

  group('WindowCaptionControls tests', () {
    testWidgets('WindowCaptionControls renders properly with custom height',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            appBar: PreferredSize(
              preferredSize: Size.fromHeight(40),
              child: Row(
                children: [
                  WindowCaptionControls(height: 36),
                ],
              ),
            ),
            body: SizedBox.shrink(),
          ),
        ),
      );

      expect(find.byType(WindowCaptionControls), findsOneWidget);
    });
  });

  group('AuthState theme and window preferences tests', () {
    test('Default values strictly adhere to security and design specifications',
        () {
      final auth = AuthState();
      // Always-on-top default must be false (no intrusive window stacking)
      expect(auth.alwaysOnTop, isFalse);
      // Bring-to-front on prompt must be false (prevention of keystroke hijacking / CWE-1021)
      expect(auth.bringToFrontOnPrompt, isFalse);
      // Bring-to-front on message must be false
      expect(auth.bringToFrontOnMessage, isFalse);
      // Default theme is slate_minimal
      expect(auth.appTheme, equals('slate_minimal'));
      // Default animation mode is static (0% CPU / battery saving)
      expect(auth.bgAnimation, equals('static'));
    });

    test('Preference mutations update state and notify listeners', () async {
      final auth = AuthState();
      int notifyCount = 0;
      auth.addListener(() => notifyCount++);

      await auth.setAlwaysOnTop(true);
      expect(auth.alwaysOnTop, isTrue);
      expect(notifyCount, 1);

      await auth.setBringToFrontOnPrompt(true);
      expect(auth.bringToFrontOnPrompt, isTrue);
      expect(notifyCount, 2);

      await auth.setBringToFrontOnMessage(true);
      expect(auth.bringToFrontOnMessage, isTrue);
      expect(notifyCount, 3);

      await auth.setAppTheme('deep_cyber');
      expect(auth.appTheme, equals('deep_cyber'));
      expect(notifyCount, 4);

      await auth.setAppTheme('nordic_frost');
      expect(auth.appTheme, equals('nordic_frost'));
      expect(notifyCount, 5);

      await auth.setBgAnimation('animated');
      expect(auth.bgAnimation, equals('animated'));
      expect(notifyCount, 6);

      await auth.setBgAnimation('off');
      expect(auth.bgAnimation, equals('off'));
      expect(notifyCount, 7);
    });
  });

  group('NeuralMeshBackground adaptive behavior tests', () {
    testWidgets('renders child cleanly with static and animated modes',
        (tester) async {
      final auth = AuthState();

      await tester.pumpWidget(
        ChangeNotifierProvider<AuthState>.value(
          value: auth,
          child: const MaterialApp(
            home: Scaffold(
              body: NeuralMeshBackground(
                child: Text('Protected Surface'),
              ),
            ),
          ),
        ),
      );

      expect(find.text('Protected Surface'), findsOneWidget);

      // Change theme to deep_cyber
      await auth.setAppTheme('deep_cyber');
      await tester.pump();
      expect(find.text('Protected Surface'), findsOneWidget);

      // Change theme to nordic_frost
      await auth.setAppTheme('nordic_frost');
      await tester.pump();
      expect(find.text('Protected Surface'), findsOneWidget);

      // Change bg animation to off
      await auth.setBgAnimation('off');
      await tester.pump();
      expect(find.text('Protected Surface'), findsOneWidget);
    });
  });

  group('SettingsScreen cards for Appearance and Window Behavior', () {
    testWidgets('renders appearance and window behavior settings',
        (tester) async {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final auth = AuthState();

      await tester.pumpWidget(
        ChangeNotifierProvider<AuthState>.value(
          value: auth,
          child: const MaterialApp(
            home: SettingsScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Check Appearance card section title
      expect(
        find.textContaining('Оформление и фоновые эффекты'),
        findsOneWidget,
      );

      // Check Theme chips
      expect(find.text('Slate Dark'), findsOneWidget);
      expect(find.text('Cyber Neon'), findsOneWidget);
      expect(find.text('Nordic Light'), findsOneWidget);

      // Check Animation mode chips
      expect(find.text('Анимация'), findsOneWidget);
      expect(find.text('Статично'), findsOneWidget);
      expect(find.text('Отключено'), findsOneWidget);

      // Check Window behavior section title
      expect(
        find.textContaining('Поведение окна и фокус'),
        findsOneWidget,
      );

      // Check Switches exist
      expect(find.text('Поверх всех окон'), findsOneWidget);
      expect(find.text('Вызов окна при запросе 2FA'), findsOneWidget);
      expect(find.text('Вызов окна при сообщении в чате'), findsOneWidget);

      // Tap Theme chip
      await tester.tap(find.text('Cyber Neon'));
      await tester.pumpAndSettle();
      expect(auth.appTheme, equals('deep_cyber'));

      // Tap Animation mode chip
      await tester.tap(find.text('Отключено'));
      await tester.pumpAndSettle();
      expect(auth.bgAnimation, equals('off'));
    });
  });
}
