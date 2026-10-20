import 'dart:io';

import 'input_injector.dart';

class LinkHostReadinessException implements Exception {
  const LinkHostReadinessException(this.reason);

  final String reason;

  @override
  String toString() => 'LinkHostReadinessException($reason)';
}

void validateLinkHostInputReadiness({
  required String osFamily,
  bool? macAccessibilityTrusted,
  String? linuxSessionType,
  bool linuxInputAvailable = false,
}) {
  if (osFamily == 'macos' && macAccessibilityTrusted != true) {
    throw const LinkHostReadinessException(
        'host_accessibility_permission_required');
  }
  if (osFamily == 'linux') {
    if (linuxSessionType == 'wayland') {
      throw const LinkHostReadinessException(
          'host_wayland_control_unavailable');
    }
    if (linuxSessionType != 'x11' || !linuxInputAvailable) {
      throw const LinkHostReadinessException('host_linux_input_unavailable');
    }
  }
}

Future<void> ensureLinkHostInputReady({required bool allowControl}) async {
  if (!allowControl) return;
  if (Platform.isMacOS) {
    validateLinkHostInputReadiness(
      osFamily: 'macos',
      macAccessibilityTrusted: InputInjector.instance.macAccessibilityTrusted,
    );
  } else if (Platform.isLinux) {
    String? sessionType;
    var inputAvailable = false;
    try {
      final session = await Process.run(
        'loginctl',
        const ['show-session', 'auto', '--property=Type', '--value'],
      ).timeout(const Duration(seconds: 3));
      if (session.exitCode == 0) sessionType = session.stdout.toString().trim();
      // A systemd user service may have no calling login session. Older
      // loginctl releases also lack the special 'auto' selector.
      if (sessionType != 'x11' && sessionType != 'wayland') {
        final user = await Process.run('id', const ['-u'])
            .timeout(const Duration(seconds: 2));
        final uid = user.stdout.toString().trim();
        if (user.exitCode == 0 && RegExp(r'^[0-9]+$').hasMatch(uid)) {
          final display = await Process.run('loginctl',
              ['show-user', uid, '--property=Display', '--value'])
              .timeout(const Duration(seconds: 2));
          final sessionID = display.stdout.toString().trim();
          if (display.exitCode == 0 &&
              RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(sessionID)) {
            final graphical = await Process.run('loginctl',
                ['show-session', sessionID, '--property=Type', '--value'])
                .timeout(const Duration(seconds: 2));
            if (graphical.exitCode == 0) {
              sessionType = graphical.stdout.toString().trim();
            }
          }
        }
      }
      if (sessionType == 'x11') {
        final input = await Process.run('xdotool', const ['getdisplaygeometry'])
            .timeout(const Duration(seconds: 3));
        inputAvailable = input.exitCode == 0;
      }
    } on Object {
      // Missing commands, denied display access and unknown sessions all fail
      // closed for control; view-only screen sharing remains available.
    }
    validateLinkHostInputReadiness(
      osFamily: 'linux',
      linuxSessionType: sessionType,
      linuxInputAvailable: inputAvailable,
    );
  }
}
