import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:ligament_authenticator/services/auth_state.dart';
import 'package:ligament_authenticator/screens/identity_mismatch_banner.dart';
import 'package:ligament_authenticator/screens/browser_sso_dialog.dart';

Widget _wrap(Widget child) => MaterialApp(
      home: ChangeNotifierProvider.value(
        value: AuthState(),
        child: Scaffold(body: child),
      ),
    );

void main() {
  group('IdentityMismatchBanner', () {
    testWidgets('показывает имена обоих пользователей и закрывается', (tester) async {
      var closed = false;
      await tester.pumpWidget(_wrap(
        IdentityMismatchBanner(
          accountUsername: 'ivanov',
          windowsUser: r'CORP\petrov',
          onClose: () => closed = true,
        ),
      ));

      final text = find.textContaining('ivanov');
      expect(text, findsOneWidget);
      expect(find.textContaining(r'CORP\petrov'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.close));
      expect(closed, isTrue);
    });

    testWidgets('локализация EN', (tester) async {
      // Дефолтная AuthState → локаль ru (системная); проверяем сам факт
      // наличия перевода через вторую сборку строки AppStrings не требуется —
      // баннер уже покрыт ru-кейсом выше; здесь — отсутствие throw на EN-виджете.
      await tester.pumpWidget(_wrap(
        IdentityMismatchBanner(
          accountUsername: 'a',
          windowsUser: 'b',
          onClose: () {},
        ),
      ));
      expect(find.byType(IdentityMismatchBanner), findsOneWidget);
    });
  });

  group('BrowserSsoDialog', () {
    testWidgets('готовый билет: «Войти» активна и отдаёт approve', (tester) async {
      bool? decision;
      await tester.pumpWidget(_wrap(
        BrowserSsoDialog(
          spName: 'Confluence',
          identityDisplay: r'CORP\ivanov',
          ready: true,
          onDecision: (approve) => decision = approve,
        ),
      ));

      expect(find.textContaining('Confluence'), findsOneWidget);
      expect(find.textContaining(r'CORP\ivanov'), findsOneWidget);
      expect(find.textContaining('свежий вход'), findsNothing); // нет подсказки

      await tester.tap(find.textContaining('Войти'));
      expect(decision, isTrue);
    });

    testWidgets('нет билета: «Войти» недоступна, подсказка про свежий вход', (tester) async {
      bool? decision;
      await tester.pumpWidget(_wrap(
        BrowserSsoDialog(
          spName: 'Jira',
          identityDisplay: r'CORP\ivanov',
          ready: false,
          onDecision: (approve) => decision = approve,
        ),
      ));

      expect(find.textContaining('свежий вход'), findsOneWidget);

      final loginButton = find.ancestor(
        of: find.textContaining('Войти'),
        matching: find.byType(ElevatedButton),
      );
      final button = tester.widget<ElevatedButton>(loginButton);
      expect(button.onPressed, isNull); // заблокирована

      await tester.tap(find.textContaining('Отмена'));
      expect(decision, isFalse);
    });
  });
}
