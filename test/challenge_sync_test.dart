import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ligament_authenticator/screens/approval_modal.dart';
import 'package:ligament_authenticator/services/auth_state.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('xyz.luan/audioplayers'), (_) async => null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('xyz.luan/audioplayers.global'), (_) async => null);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('xyz.luan/audioplayers'), null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('xyz.luan/audioplayers.global'), null);
  });

  group('Challenge Synchronization (Cross-Delivery)', () {
    test('handleChallengeResolved immediately dismisses activePrompt and cleans pending list', () {
      final auth = AuthState();
      const chId = '550e8400-e29b-41d4-a716-446655440000';

      auth.activePrompt = {
        'challenge_id': chId,
        'who': 'Иван Иванов',
        'service': 'VPN Corporate',
        'expires_in_seconds': 300,
        'metadata': {'attempt_id': 'attempt-99'},
      };
      auth.pendingChallenges = [
        {'id': chId, 'purpose': 'vpn', 'expires_in_seconds': 300},
        {'id': 'other-id', 'purpose': 'web', 'expires_in_seconds': 120},
      ];

      expect(auth.activePrompt, isNotNull);
      expect(auth.pendingChallenges.length, 2);
      expect(auth.isChallengeResolved(chId), isFalse);

      // Симуляция получения события от Telegram бота / другого устройства
      auth.handleChallengeResolved(chId, 'approved', 'attempt-99');

      expect(auth.activePrompt, isNull, reason: 'activePrompt должен быть сброшен мгновенно');
      expect(auth.isChallengeResolved(chId), isTrue);
      expect(auth.pendingChallenges.any((c) => c['id'] == chId), isFalse);
      expect(auth.pendingChallenges.length, 1);
    });

    test('handleChallengeResolved by attemptId dismisses prompt even if challengeId is different sibling', () {
      final auth = AuthState();
      const siblingAppId = 'app-ch-123';
      const tgAttemptId = 'common-attempt-777';

      auth.activePrompt = {
        'challenge_id': siblingAppId,
        'who': 'Петр Петров',
        'service': 'Wi-Fi 802.1X',
        'expires_in_seconds': 300,
        'metadata': {'attempt_id': tgAttemptId},
      };

      expect(auth.activePrompt, isNotNull);

      // Telegram бот закрыл свой telegram_push челлендж с общим attempt_id
      auth.handleChallengeResolved('tg-ch-456', 'approved', tgAttemptId);

      expect(auth.activePrompt, isNull, reason: 'Сиблинг того же attempt_id должен быть закрыт');
    });

    testWidgets('ApprovalModal closes immediately upon handleChallengeResolved without waiting 300s', (tester) async {
      final auth = AuthState();
      const chId = 'modal-test-ch-001';

      auth.activePrompt = {
        'challenge_id': chId,
        'who': 'Сотрудник',
        'service': 'Корпоративный доступ',
        'expires_in_seconds': 300,
        'number_match': '42',
      };

      await tester.pumpWidget(
        ChangeNotifierProvider<AuthState>.value(
          value: auth,
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => ElevatedButton(
                  onPressed: () {
                    showDialog(
                      context: context,
                      builder: (_) => ApprovalModal(prompt: auth.activePrompt!),
                    );
                  },
                  child: const Text('Show'),
                ),
              ),
            ),
          ),
        ),
      );

      // Открываем диалог подтверждения
      await tester.tap(find.text('Show'));
      await tester.pumpAndSettle();

      expect(find.byType(ApprovalModal), findsOneWidget);
      expect(find.text('Корпоративный доступ'), findsOneWidget);

      // Подтверждение или отказ пришёл из Telegram в реальном времени
      auth.handleChallengeResolved(chId, 'approved');
      await tester.pumpAndSettle();

      // Диалог должен мгновенно закрыться
      expect(find.byType(ApprovalModal), findsNothing, reason: 'Диалог должен закрыться сразу, не дожидаясь 300с');
    });
  });
}
