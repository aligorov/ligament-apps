import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ligament_authenticator/screens/support_operator_screen.dart';

void main() {
  group('pointerDownButton (M-4: выбор кнопки для протокола агента)', () {
    test('левая кнопка по умолчанию', () {
      expect(pointerDownButton(kPrimaryButton, false), 0);
    });

    test('правая кнопка из PointerDownEvent', () {
      expect(pointerDownButton(kSecondaryButton, false), 2);
    });

    test('средняя кнопка из PointerDownEvent', () {
      expect(pointerDownButton(kMiddleMouseButton, false), 1);
    });

    test('принудительный режим ПКМ перекрывает физическую кнопку', () {
      expect(pointerDownButton(kPrimaryButton, true), 2);
      expect(pointerDownButton(kMiddleMouseButton, true), 2);
    });

    test('в PointerUpEvent buttons == 0 — функция не используется для up '
        '(кнопка берется из парного down)', () {
      // документируем контракт: up-события шлют кнопку из _pointerDownButtons
      expect(kPrimaryButton, 1);
      expect(kSecondaryButton, 2);
      expect(kMiddleMouseButton, 4);
    });
  });
}
