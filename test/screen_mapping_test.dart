import 'package:flutter_test/flutter_test.dart';
import 'package:ligament_authenticator/services/input_injector.dart';

void main() {
  group('ScreenRect', () {
    test('fromJsonLTRB корректно строится из RECT (left/top/right/bottom)', () {
      final r = ScreenRect.fromLTRB(0, 0, 1920, 1080);
      expect(r.width, 1920);
      expect(r.height, 1080);
      expect(r.right, 1920);
      expect(r.bottom, 1080);
    });

    test('toJson содержит x/y/width/height', () {
      const r = ScreenRect(-1920, 0, 1920, 1080);
      expect(r.toJson(), {'x': -1920, 'y': 0, 'width': 1920, 'height': 1080});
    });

    test('равенство по всем полям', () {
      expect(const ScreenRect(1, 2, 3, 4), const ScreenRect(1, 2, 3, 4));
      expect(const ScreenRect(1, 2, 3, 4) == const ScreenRect(0, 2, 3, 4), isFalse);
    });
  });

  group('InputInjector.mapNormToRect (маппинг norm-координат в монитор)', () {
    const primary = ScreenRect(0, 0, 1920, 1080);
    const secondary = ScreenRect(1920, 0, 1280, 1024); // монитор справа от primary

    test('(0,0) -> левый верхний угол монитора', () {
      expect(InputInjector.mapNormToRect(0, 0, primary), (0, 0));
      expect(InputInjector.mapNormToRect(0, 0, secondary), (1920, 0));
    });

    test('(1,1) -> правый нижний пиксель монитора', () {
      expect(InputInjector.mapNormToRect(1, 1, primary), (1919, 1079));
      expect(InputInjector.mapNormToRect(1, 1, secondary), (3199, 1023));
    });

    test('(0.5,0.5) -> центр монитора', () {
      final (x, y) = InputInjector.mapNormToRect(0.5, 0.5, secondary);
      // 1920 + round(0.5 * 1279) = 2560; round(0.5 * 1023) = 512
      expect(x, 2560);
      expect(y, 512);
    });

    test('выход за 0..1 клампится в границы монитора', () {
      expect(InputInjector.mapNormToRect(-5, -0.1, secondary), (1920, 0));
      expect(InputInjector.mapNormToRect(2, 9, secondary), (3199, 1023));
    });

    test('NaN координаты не роняют маппинг', () {
      expect(InputInjector.mapNormToRect(double.nan, double.nan, primary), (0, 0));
    });

    test('монитор с отрицательными координатами (слева от primary)', () {
      const left = ScreenRect(-1280, 0, 1280, 720);
      expect(InputInjector.mapNormToRect(0, 0, left), (-1280, 0));
      expect(InputInjector.mapNormToRect(1, 1, left), (-1, 719));
      final (x, y) = InputInjector.mapNormToRect(0.5, 0.5, left);
      // -1280 + 0.5*1279 = -640.5, Dart round() — от нуля: -641
      expect(x, -641);
      expect(y, 360); // round(0.5 * 719) = 360
    });

    test('вырожденный rect 1x1 не делит на ноль', () {
      expect(InputInjector.mapNormToRect(0.5, 0.5, const ScreenRect(10, 10, 1, 1)), (10, 10));
    });
  });

  group('InputInjector.normalizeVirtualDeskAxis (MOUSEEVENTF_VIRTUALDESK)', () {
    test('края виртуального стола -> 0 и 65535', () {
      expect(InputInjector.normalizeVirtualDeskAxis(0, 0, 3840), 0);
      expect(InputInjector.normalizeVirtualDeskAxis(3840, 0, 3840), 65535);
    });

    test('смещённый виртуальный стол учитывает virtMin', () {
      // стол с x=-1920 шириной 3840: точка x=0 — около центра
      expect(InputInjector.normalizeVirtualDeskAxis(-1920, -1920, 3840), 0);
      final center = InputInjector.normalizeVirtualDeskAxis(0, -1920, 3840);
      expect(center, greaterThan(32700));
      expect(center, lessThan(32835));
      expect(InputInjector.normalizeVirtualDeskAxis(1920, -1920, 3840), 65535);
    });

    test('выход за границы клампится', () {
      expect(InputInjector.normalizeVirtualDeskAxis(-99999, 0, 1920), 0);
      expect(InputInjector.normalizeVirtualDeskAxis(99999, 0, 1920), 65535);
    });

    test('virtSize <= 1 безопасно возвращает 0', () {
      expect(InputInjector.normalizeVirtualDeskAxis(5, 0, 1), 0);
      expect(InputInjector.normalizeVirtualDeskAxis(5, 0, 0), 0);
    });
  });
}
