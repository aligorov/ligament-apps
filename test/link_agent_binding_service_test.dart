import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:ligament_authenticator/services/link_agent_binding_service.dart';

void main() {
  test('binding diagnostic shows only the numeric Win32 error', () {
    final error = PlatformException(
      code: 'link_agent_service_session_check_failed',
      message: 'Cannot verify Link service pipe session (Win32 error 5) secret',
    );
    final message = linkAgentBindingErrorMessage(error, isRu: true);
    expect(message, contains('Named Pipe'));
    expect(message, contains('Win32: 5'));
    expect(message, isNot(contains('secret')));
  });
  test('Unix agent binding socket is scoped to a numeric user ID', () {
    expect(
        linkAgentBindingSocketPath(501), '/tmp/ligament-agent-501/bind.sock');
    expect(() => linkAgentBindingSocketPath(-1), throwsArgumentError);
  });

  test('binding failures are translated to actionable localized messages', () {
    final mismatch = PlatformException(code: 'link_agent_server_mismatch');
    expect(
      linkAgentBindingErrorMessage(mismatch, isRu: true),
      contains('SERVERURL'),
    );
    expect(
      linkAgentBindingErrorMessage(
        PlatformException(code: 'link_agent_service_not_running'),
        isRu: false,
      ),
      contains('Windows Services'),
    );
    expect(
      linkAgentBindingErrorMessage(
        PlatformException(code: 'link_agent_launchd_failed'),
        isRu: true,
      ),
      contains('Applications'),
    );
  });
}
