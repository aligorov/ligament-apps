import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ligament_authenticator/services/remote_keyboard.dart';
import 'package:ligament_authenticator/services/support_service.dart';

void main() {
  test(
      'service console permits every input and clipboard command but excludes files',
      () {
    for (final command in [
      'screen_list',
      'switch_screen',
      'mouse_move',
      'mouse_down',
      'mouse_up',
      'wheel',
      'key_down',
      'key_up',
      'hotkey',
      'block_input',
      'text_input',
      'clipboard_set',
      'clipboard_get'
    ]) {
      expect(SupportService.serviceHostCommandAllowed(command), isTrue,
          reason: command);
    }
    for (final command in [
      'file_start',
      'file_chunk',
      'file_end',
      'shell',
      'chat_message'
    ]) {
      expect(SupportService.serviceHostCommandAllowed(command), isFalse,
          reason: command);
    }
  });
  test('left/right modifiers and navigation use Windows key codes', () {
    for (final entry in <PhysicalKeyboardKey, int>{
      PhysicalKeyboardKey.shiftLeft: 0xa0,
      PhysicalKeyboardKey.shiftRight: 0xa1,
      PhysicalKeyboardKey.altLeft: 0xa4,
      PhysicalKeyboardKey.altRight: 0xa5,
      PhysicalKeyboardKey.controlLeft: 0xa2,
      PhysicalKeyboardKey.controlRight: 0xa3,
      PhysicalKeyboardKey.metaLeft: 0x5b,
      PhysicalKeyboardKey.metaRight: 0x5c,
      PhysicalKeyboardKey.arrowLeft: 0x25,
      PhysicalKeyboardKey.space: 0x20,
    }.entries) {
      final keyboard = RemoteKeyboard();
      final down = keyboard.message(KeyDownEvent(
        physicalKey: entry.key,
        logicalKey: LogicalKeyboardKey.shiftLeft,
        timeStamp: Duration.zero,
      ));
      expect(down['keyCode'], entry.value);
      final up = keyboard.message(KeyUpEvent(
        physicalKey: entry.key,
        logicalKey: LogicalKeyboardKey.shiftRight,
        timeStamp: Duration.zero,
      ));
      expect(up, {...down, 'type': 'key_up'});
    }
  });
  test('Unicode key release keeps the original text after a layout change', () {
    final keyboard = RemoteKeyboard();
    keyboard.message(const KeyDownEvent(
      physicalKey: PhysicalKeyboardKey.keyF,
      logicalKey: LogicalKeyboardKey.keyF,
      character: 'а',
      timeStamp: Duration.zero,
    ));
    final up = keyboard.message(const KeyUpEvent(
      physicalKey: PhysicalKeyboardKey.keyF,
      logicalKey: LogicalKeyboardKey.keyF,
      timeStamp: Duration.zero,
    ));
    expect(up['char'], 'а');
    expect(up['keyCode'], 0x46);
    expect(keyboard.releaseAll(), isEmpty);
  });
  test('focus loss releases all physical identities, including repeated keys',
      () {
    final keyboard = RemoteKeyboard();
    keyboard.message(const KeyDownEvent(
      physicalKey: PhysicalKeyboardKey.keyA,
      logicalKey: LogicalKeyboardKey.keyA,
      character: 'a',
      timeStamp: Duration.zero,
    ));
    keyboard.message(const KeyRepeatEvent(
      physicalKey: PhysicalKeyboardKey.keyA,
      logicalKey: LogicalKeyboardKey.keyA,
      character: 'A',
      timeStamp: Duration.zero,
    ));
    expect(keyboard.releaseAll(), [
      {'type': 'key_up', 'key': 'A', 'keyCode': 0x41, 'char': 'a'},
    ]);
    expect(keyboard.releaseAll(), isEmpty);
  });
}
