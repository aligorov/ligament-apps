import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:ligament_authenticator/services/auth_state.dart';
import 'package:ligament_authenticator/screens/notifications_modal.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AuthState Notifications Logic', () {
    testWidgets('notifications state initializes empty', (tester) async {
      final auth = AuthState();
      expect(auth.notifications, isEmpty);
      expect(auth.unreadNotificationsCount, 0);
    });

    testWidgets('unreadNotificationsCount calculates correctly based on is_read and read_at', (tester) async {
      final auth = AuthState();
      auth.notifications = [
        {
          'id': '1',
          'subject': 'Alert 1',
          'body': 'Content 1',
          'source': 'telegram',
          'is_read': false,
          'read_at': null,
        },
        {
          'id': '2',
          'subject': 'Alert 2',
          'body': 'Content 2',
          'source': 'radius',
          'is_read': true,
          'read_at': '2026-09-20T10:00:00Z',
        },
        {
          'id': '3',
          'subject': 'Alert 3',
          'body': 'Content 3',
          'source': 'app',
          'is_read': false,
          'read_at': null,
        },
      ];
      auth.unreadNotificationsCount =
          auth.notifications.where((n) => n['is_read'] != true && n['read_at'] == null).length;

      expect(auth.unreadNotificationsCount, 2);
    });
  });

  group('NotificationsModal Widget', () {
    testWidgets('renders empty state when there are no notifications', (WidgetTester tester) async {
      final auth = AuthState();
      auth.notifications = [];
      auth.unreadNotificationsCount = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider<AuthState>.value(
            value: auth,
            child: const Scaffold(
              body: NotificationsModal(),
            ),
          ),
        ),
      );

      expect(find.text('Центр уведомлений'), findsOneWidget);
      expect(find.text('Входящих уведомлений пока нет'), findsOneWidget);
      expect(find.byIcon(Icons.notifications_none_rounded), findsOneWidget);
    });

    testWidgets('renders notification items with subject, body, and source badge', (WidgetTester tester) async {
      final auth = AuthState();
      auth.notifications = [
        {
          'id': 'n1',
          'subject': 'Успешный вход через RADIUS',
          'body': 'Пользователь test_user вошел в корпоративную сеть',
          'source': 'radius',
          'status': 'sent',
          'created_at': '2026-09-20T10:30:00Z',
          'is_read': false,
          'read_at': null,
        },
      ];
      auth.unreadNotificationsCount = 1;

      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider<AuthState>.value(
            value: auth,
            child: const Scaffold(
              body: NotificationsModal(),
            ),
          ),
        ),
      );

      expect(find.text('Центр уведомлений'), findsOneWidget);
      expect(find.text('Успешный вход через RADIUS'), findsOneWidget);
      expect(find.text('Пользователь test_user вошел в корпоративную сеть'), findsOneWidget);
      expect(find.text('RADIUS'), findsOneWidget);
      expect(find.byIcon(Icons.done_all), findsOneWidget);
    });
  });
}
