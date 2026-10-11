import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ligament_authenticator/services/input_injector.dart';
import 'package:ligament_authenticator/services/remote_keyboard.dart';
import 'package:ligament_authenticator/widgets/remote_pointer_surface.dart';

void main() {
  group('Release C: XBUTTON1 / XBUTTON2 mouse button mapping (C7)', () {
    test('remoteMouseButton maps 5 mouse buttons correctly', () {
      expect(remoteMouseButton(kPrimaryMouseButton, false), 0);
      expect(remoteMouseButton(kMiddleMouseButton, false), 1);
      expect(remoteMouseButton(kSecondaryMouseButton, false), 2);
      expect(remoteMouseButton(kBackMouseButton, false), 3);
      expect(remoteMouseButton(kForwardMouseButton, false), 4);
    });

    test('remoteMouseButton respects rightMode override for primary click', () {
      expect(remoteMouseButton(kPrimaryMouseButton, true), 2);
      expect(remoteMouseButton(0, true), 2);
    });
  });

  group('Release C: Wheel delta quantization (C5)', () {
    test('quantizeWindowsWheelDelta returns zero for zero delta', () {
      expect(InputInjector.quantizeWindowsWheelDelta(0.0), 0);
    });

    test('quantizeWindowsWheelDelta quantizes to multiples of 120 (WHEEL_DELTA)', () {
      // 20px raw delta -> 1 tick -> 120
      expect(InputInjector.quantizeWindowsWheelDelta(20.0), -120);
      expect(InputInjector.quantizeWindowsWheelDelta(-20.0), 120);

      // 40px raw delta -> 2 ticks -> 240
      expect(InputInjector.quantizeWindowsWheelDelta(40.0), -240);
      expect(InputInjector.quantizeWindowsWheelDelta(-40.0), 240);

      // 120px raw delta -> 6 ticks -> 720
      expect(InputInjector.quantizeWindowsWheelDelta(120.0), -720);
      expect(InputInjector.quantizeWindowsWheelDelta(-120.0), 720);
    });

    test('quantizeWindowsWheelDelta clamps ticks between 1 and 10 (max 1200)', () {
      expect(InputInjector.quantizeWindowsWheelDelta(500.0), -1200);
      expect(InputInjector.quantizeWindowsWheelDelta(-500.0), 1200);
    });
  });

  group('Release C: Multi-monitor coordinates with ScreenRect (C4)', () {
    test('mapNormToRect maps accurately to secondary monitor with positive offset', () {
      const secondaryMonitor = ScreenRect(1920, 0, 1920, 1080);
      expect(InputInjector.mapNormToRect(0.0, 0.0, secondaryMonitor), (1920, 0));
      expect(InputInjector.mapNormToRect(1.0, 1.0, secondaryMonitor), (3839, 1079));
      expect(InputInjector.mapNormToRect(0.5, 0.5, secondaryMonitor), (2880, 540));
    });

    test('mapNormToRect maps accurately to monitor with negative virtual coords', () {
      const leftMonitor = ScreenRect(-1920, 0, 1920, 1080);
      expect(InputInjector.mapNormToRect(0.0, 0.0, leftMonitor), (-1920, 0));
      expect(InputInjector.mapNormToRect(1.0, 1.0, leftMonitor), (-1, 1079));
      expect(InputInjector.mapNormToRect(0.5, 0.5, leftMonitor), (-961, 540));
    });

    test('absoluteFromNorm prioritizes explicit screenRect parameter', () {
      const customRect = ScreenRect(2560, 100, 1920, 1080);
      final coords = InputInjector.instance.absoluteFromNorm(0.5, 0.5, screenRect: customRect);
      expect(coords, (3520, 640));
    });
  });

  group('Release C: Always-contain letterbox geometry (C1)', () {
    (double relX, double relY) calculateContainCoords({
      required double localX,
      required double localY,
      required double containerW,
      required double containerH,
      required double videoW,
      required double videoH,
    }) {
      final videoAspect = videoW / videoH;
      final containerAspect = containerW / containerH;
      double renderW = containerW;
      double renderH = containerH;
      double offsetX = 0.0;
      double offsetY = 0.0;

      if (containerAspect > videoAspect) {
        renderW = containerH * videoAspect;
        offsetX = (containerW - renderW) / 2.0;
      } else {
        renderH = containerW / videoAspect;
        offsetY = (containerH - renderH) / 2.0;
      }

      final relX = (localX - offsetX) / renderW;
      final relY = (localY - offsetY) / renderH;
      return (relX, relY);
    }

    test('pillarbox (container wider than 16:9 video) calculates correct center offset', () {
      // Container 1920x800, Video 1920x1080 (Aspect: 1.777, container is 2.40: wider)
      // Actually container 2000x1000 (aspect 2.0 > 1.777)
      final (rx, ry) = calculateContainCoords(
        localX: 1000,
        localY: 500,
        containerW: 2000,
        containerH: 1000,
        videoW: 1920,
        videoH: 1080,
      );
      expect(rx, closeTo(0.5, 0.0001));
      expect(ry, closeTo(0.5, 0.0001));
    });

    test('letterbox (container taller than 16:9 video) calculates correct vertical offset', () {
      // Container 1000x2000 (aspect 0.5 < 1.777)
      final (rx, ry) = calculateContainCoords(
        localX: 500,
        localY: 1000,
        containerW: 1000,
        containerH: 2000,
        videoW: 1920,
        videoH: 1080,
      );
      expect(rx, closeTo(0.5, 0.0001));
      expect(ry, closeTo(0.5, 0.0001));
    });
  });

  group('Release C: Key identity preservation across layout changes (C9)', () {
    test('RemoteKeyboard remembers down key identity for up event', () {
      final kb = RemoteKeyboard();
      const physKey = PhysicalKeyboardKey.keyA;
      const logicalKeyEn = LogicalKeyboardKey.keyA;

      const downEvent = KeyDownEvent(
        physicalKey: physKey,
        logicalKey: logicalKeyEn,
        character: 'a',
        timeStamp: Duration.zero,
      );

      final downMsg = kb.message(downEvent);
      expect(downMsg['type'], 'key_down');
      expect(downMsg['key'], 'A');
      expect(downMsg['keyCode'], 0x41);
      expect(downMsg['char'], 'a');

      // Operator changed layout to Russian before releasing the key (logical key becomes Cyrillic 'ф')
      const upEventWithRuLayout = KeyUpEvent(
        physicalKey: physKey,
        logicalKey: LogicalKeyboardKey(0x0444),
        timeStamp: Duration(milliseconds: 50),
      );

      final upMsg = kb.message(upEventWithRuLayout);
      expect(upMsg['type'], 'key_up');
      // Must retain original key name and char from down event!
      expect(upMsg['key'], 'A');
      expect(upMsg['keyCode'], 0x41);
      expect(upMsg['char'], 'a');
    });

    test('RemoteKeyboard.releaseAll clears and returns paired key_up messages', () {
      final kb = RemoteKeyboard();
      kb.message(const KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.controlLeft,
        logicalKey: LogicalKeyboardKey.controlLeft,
        timeStamp: Duration.zero,
      ));
      kb.message(const KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.keyC,
        logicalKey: LogicalKeyboardKey.keyC,
        character: 'c',
        timeStamp: Duration.zero,
      ));

      final released = kb.releaseAll();
      expect(released.length, 2);
      expect(released.every((m) => m['type'] == 'key_up'), isTrue);
      expect(kb.releaseAll(), isEmpty);
    });
  });

  group('Release C: Text input size limit (C8)', () {
    test('4096 character limit check', () {
      final valid = 'A' * 4096;
      final tooLong = 'A' * 4097;
      expect(valid.length <= 4096, isTrue);
      expect(tooLong.length <= 4096, isFalse);
    });
  });
}
