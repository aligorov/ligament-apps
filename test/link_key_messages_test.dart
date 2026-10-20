import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ligament_authenticator/models/link_control_messages.dart';
import 'package:ligament_authenticator/services/input_injector.dart';

void main() {
  for (final entry in [
    (LogicalKeyboardKey.enter, 0x0d, 36),
    (LogicalKeyboardKey.arrowLeft, 0x25, 123),
    (LogicalKeyboardKey.arrowRight, 0x27, 124),
    (LogicalKeyboardKey.arrowUp, 0x26, 126),
    (LogicalKeyboardKey.arrowDown, 0x28, 125),
    (LogicalKeyboardKey.controlLeft, 0x11, 59),
    (LogicalKeyboardKey.controlRight, 0x11, 62),
  ]) {
    test(
        '${entry.$1.keyLabel} preserves logical ID and uses native name mapping',
        () {
      final key = entry.$1;
      expect(key.keyId, greaterThan(0xffff));
      final message = LinkKeyMessage.tryParse(
        Map<String, Object?>.from(jsonDecode(encodeLinkControlMessage(
          LinkKeyMessage(
                  type: 'key_down', key: key.keyLabel, keyCode: key.keyId)
              .toJson(),
        )) as Map),
      )!;
      expect(message.keyCode, key.keyId);
      var calls = 0;
      void inject(
          {required String action,
          required String key,
          int? keyCode,
          String? char}) {
        calls++;
        expect(action, calls == 1 ? 'down' : 'up');
        expect(keyCode, isNull,
            reason: 'Flutter IDs must never become native codes');
        expect(InputInjector.mapToWinKeyCodeForTesting(key, keyCode), entry.$2);
        expect(InputInjector.mapToMacKeyCodeForTesting(key, keyCode), entry.$3);
      }

      message.inject(inject);
      message.release.inject(inject);
      expect(calls, 2);
      expect(message.release.keyCode, key.keyId);
    });
  }

  for (final text in ['ж', '界', '🙂', 'е\u0301']) {
    test('forwards $text unchanged on down and matching release', () {
      final message = LinkKeyMessage.tryParse({
        'type': 'key_down',
        'key': 'A',
        'keyCode': LogicalKeyboardKey.keyA.keyId,
        'char': text,
      })!;
      final received = <String?>[];
      void inject(
          {required String action,
          required String key,
          int? keyCode,
          String? char}) {
        received.add(char);
        expect(keyCode, isNull);
      }

      message.inject(inject);
      final released = LinkKeyMessage.tryParse(message.release.toJson())!;
      released.inject(inject);
      expect(received, [text, text]);
      expect(released.keyCode, message.keyCode);
    });
  }

  test('rejects malformed input instead of coercing types or truncating IDs',
      () {
    final valid = <String, Object?>{'type': 'key_down', 'key': 'Enter'};
    for (final invalid in <Map<String, Object?>>[
      {},
      {...valid, 'type': 'key_press'},
      {...valid, 'key': ''},
      {...valid, 'key': 13},
      {...valid, 'key': 'x' * 65},
      for (final code in [-1, 1.5, 13.0, '13', true, 0x20000000000000])
        {...valid, 'keyCode': code},
      for (final char in [1, true, <String>[], 'x' * 65])
        {...valid, 'char': char},
    ]) {
      expect(LinkKeyMessage.tryParse(invalid), isNull, reason: '$invalid');
    }
    expect(LinkKeyMessage.tryParse(valid), isNotNull);
    expect(
        LinkKeyMessage.tryParse({...valid, 'keyCode': 0x1fffffffffffff})!
            .keyCode,
        0x1fffffffffffff);
    expect(() => LinkKeyMessage(type: 'bad', key: 'A'), throwsArgumentError);
  });
}
