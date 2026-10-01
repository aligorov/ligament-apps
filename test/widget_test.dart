import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:ligament_authenticator/services/auth_state.dart';
import 'package:ligament_authenticator/screens/approval_modal.dart';

void main() {
  testWidgets('ApprovalModal renders challenge metadata and buttons', (WidgetTester tester) async {
    final prompt = {
      'challenge_id': '00000000-0000-0000-0000-000000000001',
      'who': 'test_employee',
      'ip': '192.168.1.50',
      'ua': 'Chrome / Windows',
      'service': 'Wi-Fi: Corporate-Secure',
      'number_match': '',
      'expires_in_seconds': 60,
    };

    final authState = AuthState();

    await tester.pumpWidget(
      MaterialApp(
        home: ChangeNotifierProvider.value(
          value: authState,
          child: Scaffold(
            body: ApprovalModal(prompt: prompt),
          ),
        ),
      ),
    );

    expect(find.text('Запрос на вход'), findsOneWidget);
    expect(find.text('Wi-Fi: Corporate-Secure'), findsOneWidget);
    expect(find.text('test_employee'), findsOneWidget);
    expect(find.textContaining('192.168.1.50'), findsOneWidget);
    expect(find.text('Принять'), findsOneWidget);
    expect(find.text('Отклонить'), findsOneWidget);
  });

  testWidgets('countdown is local: ticks down, stale same-id TTL never resets it up, closes at zero', (tester) async {
    final prompt = {
      'challenge_id': '00000000-0000-0000-0000-000000000002',
      'who': 'test_employee',
      'ip': '192.168.1.50',
      'service': 'VPN: Corporate',
      'number_match': '',
      'expires_in_seconds': 3,
    };
    final authState = AuthState();
    authState.activePrompt = Map<String, dynamic>.from(prompt);

    await tester.pumpWidget(_harness(authState, prompt));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle(); // диалог открыт, до первого тика

    expect(find.text('3 с'), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
    expect(find.text('2 с'), findsOneWidget);

    // Тот же challenge_id приходит из polling с ЗАСТЫВШИМ (более высоким)
    // TTL — счётчик не должен сбрасываться вверх.
    authState.activePrompt = Map<String, dynamic>.from(prompt)
      ..['expires_in_seconds'] = 99;
    authState.notifyListeners();
    await tester.pump();
    expect(find.text('2 с'), findsOneWidget);
    expect(find.text('99 с'), findsNothing);

    await tester.pump(const Duration(seconds: 1));
    expect(find.text('1 с'), findsOneWidget);

    // Следующий тик — ноль: модалка закрывается локально по TTL.
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.text('Запрос на вход'), findsNothing);
  });

  testWidgets('reinitializes on new challenge_id and closes when prompt disappears', (tester) async {
    final first = {
      'challenge_id': '00000000-0000-0000-0000-00000000000a',
      'who': 'user_a',
      'ip': '10.0.0.1',
      'service': 'Wi-Fi: Corporate-Secure',
      'number_match': '42',
      'expires_in_seconds': 30,
    };
    final authState = AuthState();
    authState.activePrompt = Map<String, dynamic>.from(first);

    await tester.pumpWidget(_harness(authState, first));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('user_a'), findsOneWidget);
    expect(find.text('42'), findsOneWidget); // опция number matching
    expect(find.text('30 с'), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
    expect(find.text('29 с'), findsOneWidget);

    // Следующий челлендж из очереди заменяет содержимое ТОГО ЖЕ окна:
    // полная реинициализация (число/опции/таймер), без второго диалога.
    authState.activePrompt = {
      'challenge_id': '00000000-0000-0000-0000-00000000000b',
      'who': 'user_b',
      'ip': '10.0.0.2',
      'service': 'VPN: Corporate',
      'number_match': '77',
      'expires_in_seconds': 45,
    };
    authState.notifyListeners();
    await tester.pump();

    expect(find.text('user_b'), findsOneWidget);
    expect(find.text('user_a'), findsNothing);
    expect(find.text('45 с'), findsOneWidget);
    expect(find.text('77'), findsOneWidget);
    expect(find.text('Запрос на вход'), findsOneWidget); // то же окно

    // Челлендж исчез из pending (подтверждён в Telegram / истёк на
    // сервере) — окно закрывается слушателем live == null.
    authState.activePrompt = null;
    authState.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.text('Запрос на вход'), findsNothing);
  });
}

/// Хелпер: провайдер выше MaterialApp (как в реальном приложении), кнопка
/// открывает ApprovalModal через showDialog — тогда maybePop реально
/// снимает маршрут диалога.
Widget _harness(AuthState authState, Map<String, dynamic> prompt) {
  return ChangeNotifierProvider.value(
    value: authState,
    child: MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () => showDialog(
                context: context,
                builder: (_) => ApprovalModal(prompt: prompt),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
}
