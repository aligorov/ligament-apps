import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ligament_authenticator/screens/link_session_screen.dart';
import 'package:ligament_authenticator/screens/support_operator_screen.dart';
import 'package:ligament_authenticator/services/link_host_session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Link and Console SOS Unification', () {
    testWidgets('LinkSessionScreen forwards to SupportOperatorScreen with isLink=true',
        (tester) async {
      const screen = LinkSessionScreen(
        agentId: 'agent-123',
        hostname: 'corp-workstation-01',
        accessMode: 'control',
        hostData: {
          'owner_username': 'ivanov',
          'public_ip': '198.51.100.10',
          'local_ips': ['192.168.1.50'],
          'interactive_username': 'DOMAIN\\ivanov',
        },
      );

      late BuildContext capturedContext;
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (context) {
          capturedContext = context;
          return const SizedBox.shrink();
        }),
      ));

      final widget = screen.build(capturedContext) as SupportOperatorScreen;

      expect(widget, isA<SupportOperatorScreen>());
      expect(widget.isLink, isTrue);
      expect(widget.linkAgentId, 'agent-123');
      expect(widget.linkAccessMode, 'control');
      expect(widget.ownerMode, isTrue);
      expect(widget.sessionData['hostname'], 'corp-workstation-01');
      expect(widget.sessionData['is_link'], isTrue);
      expect(widget.sessionData['owner_username'], 'ivanov');
      expect(widget.sessionData['local_ips'], ['192.168.1.50']);
      expect(widget.sessionData['interactive_username'], 'DOMAIN\\ivanov');
    });

    test('SupportOperatorScreen constructor accepts Link parameters', () {
      const operatorScreen = SupportOperatorScreen(
        sessionId: 'link_agent-456',
        isLink: true,
        linkAgentId: 'agent-456',
        linkAccessMode: 'view',
        ownerMode: false,
        sessionData: {
          'id': 'link_agent-456',
          'agent_id': 'agent-456',
          'hostname': 'dev-server',
          'access_mode': 'view',
        },
      );

      expect(operatorScreen.isLink, isTrue);
      expect(operatorScreen.linkAgentId, 'agent-456');
      expect(operatorScreen.linkAccessMode, 'view');
      expect(operatorScreen.ownerMode, isFalse);
    });
  });

  group('LinkHostSession control message validation', () {
    test('validates hotkey, screen_list, switch_screen, clipboard messages', () {
      // Valid inputs
      expect(
        LinkHostSession.isValidControlInput({
          'type': 'hotkey',
          'action': 'ctrl_alt_del',
        }),
        isTrue,
      );

      expect(
        LinkHostSession.isValidControlInput({
          'type': 'hotkey',
          'action': 'win_l',
        }),
        isTrue,
      );

      expect(
        LinkHostSession.isValidControlInput({
          'type': 'screen_list',
        }),
        isTrue,
      );

      expect(
        LinkHostSession.isValidControlInput({
          'type': 'switch_screen',
          'screen_id': '1',
        }),
        isTrue,
      );

      expect(
        LinkHostSession.isValidControlInput({
          'type': 'clipboard_set',
          'text': 'Hello from operator',
        }),
        isTrue,
      );

      expect(
        LinkHostSession.isValidControlInput({
          'type': 'clipboard_get',
        }),
        isTrue,
      );

      expect(
        LinkHostSession.isValidControlInput({
          'type': 'block_input',
          'blocked': true,
        }),
        isTrue,
      );

      expect(
        LinkHostSession.isValidControlInput({
          'type': 'ping',
        }),
        isTrue,
      );

      expect(
        LinkHostSession.isValidControlInput({
          'type': 'pong',
        }),
        isTrue,
      );

      // Invalid inputs
      expect(
        LinkHostSession.isValidControlInput({
          'type': 'hotkey',
          'action': '',
        }),
        isFalse,
      );

      expect(
        LinkHostSession.isValidControlInput({
          'type': 'switch_screen',
          'screen_id': '',
        }),
        isFalse,
      );

      expect(
        LinkHostSession.isValidControlInput({
          'type': 'unknown_type',
        }),
        isFalse,
      );
    });
  });
}
