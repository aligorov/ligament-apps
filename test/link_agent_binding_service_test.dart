import 'package:flutter_test/flutter_test.dart';
import 'package:ligament_authenticator/services/link_agent_binding_service.dart';

void main() {
  test('Unix agent binding socket is scoped to a numeric user ID', () {
    expect(
        linkAgentBindingSocketPath(501), '/tmp/ligament-agent-501/bind.sock');
    expect(() => linkAgentBindingSocketPath(-1), throwsArgumentError);
  });
}
