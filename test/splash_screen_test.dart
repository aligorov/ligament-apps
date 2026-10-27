import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ligament_authenticator/screens/splash_screen.dart';

void main() {
  testWidgets('SplashScreen animates and triggers onFinish callback',
      (WidgetTester tester) async {
    bool finished = false;

    await tester.pumpWidget(
      MaterialApp(
        home: SplashScreen(
          duration: const Duration(milliseconds: 300),
          onFinish: () => finished = true,
        ),
      ),
    );

    expect(find.byType(SplashScreen), findsOneWidget);
    expect(find.text('LIGAMENT'), findsOneWidget);
    expect(find.text('2FA'), findsOneWidget);
    expect(find.text('ZERO TRUST PROTOCOL'), findsOneWidget);
    expect(finished, isFalse);

    // Дожидаемся завершения анимации
    await tester.pumpAndSettle();

    expect(finished, isTrue);
  });

  testWidgets('SplashScreen triggers onFinish early on user tap',
      (WidgetTester tester) async {
    bool finished = false;

    await tester.pumpWidget(
      MaterialApp(
        home: SplashScreen(
          duration: const Duration(seconds: 10),
          onFinish: () => finished = true,
        ),
      ),
    );

    expect(finished, isFalse);

    // Тап пользователя пропускает анимацию
    await tester.tap(find.byType(SplashScreen));
    await tester.pump();

    expect(finished, isTrue);
  });
}
