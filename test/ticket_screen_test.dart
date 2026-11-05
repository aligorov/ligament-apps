import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ligament_authenticator/screens/ticket_screen.dart';
import 'package:ligament_authenticator/services/auth_state.dart';
import 'package:ligament_authenticator/services/ticket_service.dart';
import 'package:provider/provider.dart';

void main() {
  testWidgets('TicketScreen displays default presets and allows tab switching', (tester) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AuthState>(create: (_) => AuthState()),
          ChangeNotifierProvider<TicketService>.value(value: TicketService.instance),
        ],
        child: const MaterialApp(
          home: TicketScreen(),
        ),
      ),
    );

    await tester.pumpAndSettle();

    // Verify title and presets section
    expect(find.text('Заявки и наряды'), findsOneWidget);
    expect(find.text('⚡ Быстрый вызов в 1 клик'), findsOneWidget);
    expect(find.text('Кончился картридж'), findsOneWidget);
    expect(find.text('Завис компьютер'), findsOneWidget);
    expect(find.text('Новая заявка'), findsOneWidget);

    // Verify segmented filter buttons
    expect(find.text('Все'), findsOneWidget);
    expect(find.text('В работе'), findsOneWidget);
    expect(find.text('Завершённые'), findsOneWidget);

    // Switch tab to "В работе"
    await tester.tap(find.text('В работе'));
    await tester.pumpAndSettle();

    // Switch tab to "Завершённые"
    await tester.tap(find.text('Завершённые'));
    await tester.pumpAndSettle();
  });
}
