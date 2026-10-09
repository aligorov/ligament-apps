import 'package:flutter_test/flutter_test.dart';
import 'package:ligament_authenticator/services/input_injector.dart';

void main() {
  group('InputInjector keyboard mappings', () {
    test('Windows: Arrow keys with spaces and uppercase ("Arrow Left", etc.)', () {
      expect(InputInjector.mapToWinKeyCodeForTesting('Arrow Left'), 0x25); // VK_LEFT
      expect(InputInjector.mapToWinKeyCodeForTesting('Arrow Right'), 0x27); // VK_RIGHT
      expect(InputInjector.mapToWinKeyCodeForTesting('Arrow Up'), 0x26); // VK_UP
      expect(InputInjector.mapToWinKeyCodeForTesting('Arrow Down'), 0x28); // VK_DOWN
      expect(InputInjector.mapToWinKeyCodeForTesting('arrowleft'), 0x25);
    });

    test('Windows: Modifiers with spaces and sides ("Control Left", etc.)', () {
      expect(InputInjector.mapToWinKeyCodeForTesting('Control Left'), 0x11); // VK_CONTROL
      expect(InputInjector.mapToWinKeyCodeForTesting('Shift Left'), 0x10); // VK_SHIFT
      expect(InputInjector.mapToWinKeyCodeForTesting('Alt Left'), 0x12); // VK_MENU
      expect(InputInjector.mapToWinKeyCodeForTesting('Meta Left'), 0x5B); // VK_LWIN
      expect(InputInjector.mapToWinKeyCodeForTesting('Control'), 0x11);
    });

    test('Windows: Function and navigation keys', () {
      expect(InputInjector.mapToWinKeyCodeForTesting('Escape'), 0x1B);
      expect(InputInjector.mapToWinKeyCodeForTesting('Enter'), 0x0D);
      expect(InputInjector.mapToWinKeyCodeForTesting('Backspace'), 0x08);
      expect(InputInjector.mapToWinKeyCodeForTesting('Delete'), 0x2E);
      expect(InputInjector.mapToWinKeyCodeForTesting('Home'), 0x24);
      expect(InputInjector.mapToWinKeyCodeForTesting('End'), 0x23);
      expect(InputInjector.mapToWinKeyCodeForTesting('F5'), 0x74);
    });

    test('Windows: unknown multi-character string returns 0 instead of taking first char', () {
      expect(InputInjector.mapToWinKeyCodeForTesting('UnknownSpecialKey'), 0);
    });

    test('macOS: Arrow keys with spaces and uppercase ("Arrow Left", etc.)', () {
      expect(InputInjector.mapToMacKeyCodeForTesting('Arrow Left'), 123);
      expect(InputInjector.mapToMacKeyCodeForTesting('Arrow Right'), 124);
      expect(InputInjector.mapToMacKeyCodeForTesting('Arrow Down'), 125);
      expect(InputInjector.mapToMacKeyCodeForTesting('Arrow Up'), 126);
    });

    test('macOS: Modifiers with spaces ("Control Left", "Command Left", etc.)', () {
      expect(InputInjector.mapToMacKeyCodeForTesting('Control Left'), 59);
      expect(InputInjector.mapToMacKeyCodeForTesting('Shift Left'), 56);
      expect(InputInjector.mapToMacKeyCodeForTesting('Option Left'), 58);
      expect(InputInjector.mapToMacKeyCodeForTesting('Command Left'), 55);
      expect(InputInjector.mapToMacKeyCodeForTesting('Meta Left'), 55);
    });
  });
}
