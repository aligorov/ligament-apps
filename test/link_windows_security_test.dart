import 'package:flutter_test/flutter_test.dart';
import 'package:ligament_authenticator/services/link_windows_security.dart';

void main() {
  group('LinkWindowsSecurity', () {
    test('isSensitiveClipboard does not throw on current platform', () {
      final isSensitive = LinkWindowsSecurity.isSensitiveClipboard();
      // On non-Windows platforms (like macOS runner), it safely returns false.
      expect(isSensitive, isA<bool>());
    });
  });
}
