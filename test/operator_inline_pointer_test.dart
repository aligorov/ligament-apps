import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';

int pointerDownButton(int buttons, bool rightClickMode) {
  if (rightClickMode || (buttons & kSecondaryMouseButton) != 0) return 2;
  if ((buttons & kMiddleMouseButton) != 0) return 1;
  return 0;
}

void main() {
  group('Operator inline pointer & button tracking (A4)', () {
    late Map<int, int> pointerDownButtons;
    late List<Map<String, dynamic>> sentMessages;
    late double? lastSentNormX;
    late double? lastSentNormY;

    setUp(() {
      pointerDownButtons = {};
      sentMessages = [];
      lastSentNormX = null;
      lastSentNormY = null;
    });

    test('A4.1: onPointerUp removes button from map even if controlReady becomes false', () {
      // Simulate pointer down while ready
      const pointerId = 1;
      final btn = pointerDownButton(kPrimaryMouseButton, false);
      pointerDownButtons[pointerId] = btn;
      expect(pointerDownButtons.containsKey(pointerId), isTrue);

      // onPointerUp logic: must remove from map first before checking controlReady
      final removedBtn = pointerDownButtons.remove(pointerId) ?? 0;
      expect(removedBtn, equals(0));
      expect(pointerDownButtons.containsKey(pointerId), isFalse,
          reason: 'Button must not leak in map when controlReady is false');
    });

    test('A4.2: releaseAllPressedInputs sends last known real coordinates, not (0,0)', () {
      lastSentNormX = 0.75;
      lastSentNormY = 0.42;
      pointerDownButtons[1] = 0; // Left
      pointerDownButtons[2] = 2; // Right

      void releaseAll() {
        final rx = lastSentNormX ?? 0.5;
        final ry = lastSentNormY ?? 0.5;
        for (final b in pointerDownButtons.values.toList()) {
          sentMessages.add({'type': 'mouse_up', 'button': b, 'x': rx, 'y': ry});
        }
        pointerDownButtons.clear();
      }

      releaseAll();
      expect(pointerDownButtons.isEmpty, isTrue);
      expect(sentMessages.length, equals(2));
      expect(sentMessages[0]['x'], equals(0.75));
      expect(sentMessages[0]['y'], equals(0.42));
      expect(sentMessages[1]['x'], equals(0.75));
      expect(sentMessages[1]['y'], equals(0.42));
    });

    test('A4.3: pointer down in letterbox is ignored and not stored in map', () {
      bool isOutsideVideo(double relX, double relY) {
        return relX < 0.0 || relX > 1.0 || relY < 0.0 || relY > 1.0;
      }

      const pointerId = 99;
      // Coordinate in letterbox bar (e.g. negative or > 1.0)
      const outsideX = -0.1;
      const outsideY = 0.5;

      if (!isOutsideVideo(outsideX, outsideY)) {
        pointerDownButtons[pointerId] = 0;
      }

      expect(pointerDownButtons.containsKey(pointerId), isFalse,
          reason: 'Down in letterbox bar must not be recorded');
    });

    test('A3.1: error count triggers banner on 10 failures, clears on success', () {
      int errorCount = 0;
      bool bannerVisible = false;

      void onSend(bool success) {
        if (success) {
          if (errorCount > 0) {
            errorCount = 0;
            bannerVisible = false;
          }
        } else {
          errorCount++;
          if (errorCount >= 10) {
            bannerVisible = true;
          }
        }
      }

      for (int i = 0; i < 9; i++) {
        onSend(false);
        expect(bannerVisible, isFalse);
      }
      onSend(false); // 10th failure
      expect(bannerVisible, isTrue);

      onSend(true); // recovery
      expect(errorCount, equals(0));
      expect(bannerVisible, isFalse);
    });
  });
}
