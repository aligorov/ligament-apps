import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ligament_authenticator/services/call_session_manager.dart';
import 'package:ligament_authenticator/widgets/global_call_overlay.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget buildTestHost({required Widget child}) {
    return MaterialApp(
      theme: ThemeData.dark(useMaterial3: true),
      home: Scaffold(
        body: SizedBox.expand(
          child: Stack(
            children: [
              const SizedBox.expand(child: Center(child: Text('Background Screen'))),
              child,
            ],
          ),
        ),
      ),
    );
  }

  group('GlobalCallOverlayWidget UI & End Call Tests', () {
    late CallSessionManager manager;

    setUp(() {
      manager = CallSessionManager.instance;
      manager.endCall();
    });

    tearDown(() {
      manager.endCall();
    });

    testWidgets('Ringing state: renders top-bar "Завершить" button and bottom hangup button',
        (tester) async {
      manager.startCall(
        chatId: 'c-test-1',
        chatTitle: 'Лигоров Кирилл Михайлович',
        isVideo: false,
      );
      manager.handleRinging();

      await tester.pumpWidget(buildTestHost(child: const GlobalCallOverlayWidget()));
      await tester.pump();

      // Top bar contains "Завершить" text button with call_end icon
      expect(find.text('Завершить'), findsOneWidget);
      // Both top bar and bottom action panel have call_end icon
      expect(find.byIcon(Icons.call_end), findsNWidgets(2));

      // Tap top bar end call button
      await tester.tap(find.text('Завершить'));
      await tester.pump();

      // Call is ended, overlay hidden
      expect(manager.status, CallStatus.idle);
      expect(manager.displayMode, CallDisplayMode.hidden);
    });

    testWidgets('Calling state: renders top-bar "Отменить" button and tapping it ends call',
        (tester) async {
      manager.startCall(
        chatId: 'c-test-2',
        chatTitle: 'Лигоров Кирилл Михайлович',
        isVideo: false,
      );

      await tester.pumpWidget(buildTestHost(child: const GlobalCallOverlayWidget()));
      await tester.pump();

      expect(find.text('Отменить'), findsOneWidget);
      expect(find.byIcon(Icons.call_end), findsNWidgets(2));

      // Tap bottom hangup button
      final callEndIcons = find.byIcon(Icons.call_end);
      // Second icon is in the bottom panel
      await tester.tap(callEndIcons.last);
      await tester.pump();

      expect(manager.status, CallStatus.idle);
      expect(manager.displayMode, CallDisplayMode.hidden);
    });

    testWidgets('Escape key ends outgoing call in fullscreen overlay', (tester) async {
      manager.startCall(
        chatId: 'c-test-3',
        chatTitle: 'Лигоров Кирилл Михайлович',
        isVideo: false,
      );
      manager.handleRinging();

      await tester.pumpWidget(buildTestHost(child: const GlobalCallOverlayWidget()));
      await tester.pump();

      expect(manager.status, CallStatus.ringing);

      // Press Escape key
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      expect(manager.status, CallStatus.idle);
      expect(manager.displayMode, CallDisplayMode.hidden);
    });

    testWidgets('Incoming call: renders accept and reject large FABs without top-bar cancel button',
        (tester) async {
      manager.handleIncomingOffer(
        fromUser: 'u-kirill',
        chatId: 'c-test-4',
        offerPayload: {
          'caller_name': 'Лигоров Кирилл Михайлович',
          'is_video': false,
          'sdp': 'v=0\r\no=alice 123 456 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\n',
        },
      );

      await tester.pumpWidget(buildTestHost(child: const GlobalCallOverlayWidget()));
      await tester.pump();

      expect(manager.status, CallStatus.incoming);
      // Top bar "Завершить" / "Отменить" is NOT shown for incoming
      expect(find.text('Завершить'), findsNothing);
      expect(find.text('Отменить'), findsNothing);

      // Incoming buttons
      expect(find.text('Отклонить'), findsOneWidget);
      expect(find.text('Принять'), findsOneWidget);

      // Reject incoming call via FAB
      await tester.tap(find.byIcon(Icons.call_end));
      await tester.pump();

      expect(manager.status, CallStatus.idle);
    });
  });
}
