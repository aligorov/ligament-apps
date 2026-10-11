import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ligament_authenticator/services/service_console_host.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('ligament/service_console');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));
  for (final type in [
    'mouse_move',
    'mouse_down',
    'mouse_up',
    'wheel',
    'block_input'
  ]) {
    test('native rejection of $type is not ignored', () async {
      messenger.setMockMethodCallHandler(channel, (_) async => false);
      await expectLater(
          sendServiceConsoleInput({'type': type}), throwsStateError);
    });
  }
  test('accepted input preserves numeric coordinates and button', () async {
    MethodCall? received;
    messenger.setMockMethodCallHandler(channel, (call) async {
      received = call;
      return true;
    });
    final command = {'type': 'mouse_down', 'button': 2, 'x': 0.25, 'y': 0.75};
    await sendServiceConsoleInput(command);
    expect(received?.method, 'input');
    expect(received?.arguments, command);
  });
}
