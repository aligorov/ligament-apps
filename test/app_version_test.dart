import 'package:flutter_test/flutter_test.dart';
import 'package:ligament_authenticator/app_version.dart';

void main() {
  test('formatAppVersion hides build metadata and keeps one v prefix', () {
    expect(formatAppVersion('1.1.130+156'), 'v1.1.130');
    expect(formatAppVersion('v1.1.130'), 'v1.1.130');
    expect(formatAppVersion(' 1.1.130+156 '), 'v1.1.130');
  });

  test('update comparison ignores build metadata', () {
    expect(isAppUpdateAvailable('1.1.130+155', 'v1.1.130+156'), isFalse);
    expect(isAppUpdateAvailable('1.1.129+155', 'v1.1.130'), isTrue);
    expect(isAppUpdateAvailable('v1.1.130', '1.1.131+157'), isTrue);
    expect(isAppUpdateAvailable('1.1.131+156', 'v1.1.130'), isFalse);
  });

  test('update comparison is numeric and rejects invalid versions', () {
    expect(isAppUpdateAvailable('1.1.99+100', 'v1.1.130'), isTrue);
    expect(isAppUpdateAvailable('dev', 'v1.1.130'), isFalse);
    expect(isAppUpdateAvailable('1.1.130', 'latest'), isFalse);
    expect(
      isAppUpdateAvailable('999999999999999999999999.1.1', 'v1.1.130'),
      isFalse,
    );
  });
}
