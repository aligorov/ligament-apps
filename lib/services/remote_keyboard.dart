import 'package:flutter/services.dart';

/// Keep the same identity and Unicode character for down/up, even if the
/// operator changes layout or releases a modifier before releasing the key.
class RemoteKeyboard {
  final Map<PhysicalKeyboardKey, Map<String, dynamic>> _pressed = {};

  Map<String, dynamic> message(KeyEvent event) {
    final down = event is KeyDownEvent || event is KeyRepeatEvent;
    final identity = _pressed[event.physicalKey] ??
        {
          'key': event.logicalKey.keyLabel,
          if (_virtualKey(event.physicalKey) case final int code)
            'keyCode': code,
          if (event.character case final String text when text.isNotEmpty)
            'char': text,
        };
    if (down) {
      _pressed[event.physicalKey] = identity;
    } else {
      _pressed.remove(event.physicalKey);
    }
    return {...identity, 'type': down ? 'key_down' : 'key_up'};
  }

  List<Map<String, dynamic>> releaseAll() {
    final messages = _pressed.values
        .map((identity) => {...identity, 'type': 'key_up'})
        .toList();
    _pressed.clear();
    return messages;
  }

  static int? _virtualKey(PhysicalKeyboardKey key) {
    final usage = key.usbHidUsage;
    if (usage >= 0x70004 && usage <= 0x7001d) return 0x41 + usage - 0x70004;
    if (usage >= 0x7001e && usage <= 0x70026) return 0x31 + usage - 0x7001e;
    if (usage >= 0x7003a && usage <= 0x70045) return 0x70 + usage - 0x7003a;
    return const <int, int>{
      0x70027: 0x30,
      0x70028: 0x0d,
      0x70029: 0x1b,
      0x7002a: 0x08,
      0x7002b: 0x09,
      0x7002c: 0x20,
      0x7002d: 0xbd,
      0x7002e: 0xbb,
      0x7002f: 0xdb,
      0x70030: 0xdd,
      0x70031: 0xdc,
      0x70032: 0xdc,
      0x70033: 0xba,
      0x70034: 0xde,
      0x70035: 0xc0,
      0x70036: 0xbc,
      0x70037: 0xbe,
      0x70038: 0xbf,
      0x70039: 0x14,
      0x70046: 0x2c,
      0x70047: 0x91,
      0x70048: 0x13,
      0x70049: 0x2d,
      0x7004a: 0x24,
      0x7004b: 0x21,
      0x7004c: 0x2e,
      0x7004d: 0x23,
      0x7004e: 0x22,
      0x7004f: 0x27,
      0x70050: 0x25,
      0x70051: 0x28,
      0x70052: 0x26,
      0x70053: 0x90,
      0x70054: 0x6f,
      0x70055: 0x6a,
      0x70056: 0x6d,
      0x70057: 0x6b,
      0x70058: 0x0d,
      0x70059: 0x61,
      0x7005a: 0x62,
      0x7005b: 0x63,
      0x7005c: 0x64,
      0x7005d: 0x65,
      0x7005e: 0x66,
      0x7005f: 0x67,
      0x70060: 0x68,
      0x70061: 0x69,
      0x70062: 0x60,
      0x70063: 0x6e,
      0x70065: 0x5d,
      0x700e0: 0xa2,
      0x700e1: 0xa0,
      0x700e2: 0xa4,
      0x700e3: 0x5b,
      0x700e4: 0xa3,
      0x700e5: 0xa1,
      0x700e6: 0xa5,
      0x700e7: 0x5c,
    }[usage];
  }
}
