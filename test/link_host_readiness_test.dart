import 'package:flutter_test/flutter_test.dart';
import 'package:ligament_authenticator/services/link_host_readiness.dart';

void main() {
  Matcher rejects(String reason) => throwsA(
        isA<LinkHostReadinessException>()
            .having((e) => e.reason, 'reason', reason),
      );

  test('macOS control requires confirmed Accessibility permission', () {
    for (final trusted in [false, null]) {
      expect(
        () => validateLinkHostInputReadiness(
          osFamily: 'macos',
          macAccessibilityTrusted: trusted,
        ),
        rejects('host_accessibility_permission_required'),
      );
    }
    validateLinkHostInputReadiness(
        osFamily: 'macos', macAccessibilityTrusted: true);
  });

  test('Linux rejects Wayland and missing input instead of promising control',
      () {
    expect(
      () => validateLinkHostInputReadiness(
        osFamily: 'linux',
        linuxSessionType: 'wayland',
        linuxInputAvailable: true,
      ),
      rejects('host_wayland_control_unavailable'),
    );
    expect(
      () => validateLinkHostInputReadiness(
          osFamily: 'linux', linuxSessionType: 'x11'),
      rejects('host_linux_input_unavailable'),
    );
    validateLinkHostInputReadiness(
      osFamily: 'linux',
      linuxSessionType: 'x11',
      linuxInputAvailable: true,
    );
  });

  test('view-only requests do not require input permission', () async {
    await ensureLinkHostInputReady(allowControl: false);
  });
}
