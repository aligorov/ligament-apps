import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:ligament_authenticator/services/auth_state.dart';
import 'package:ligament_authenticator/services/rdp_service.dart';
import 'package:ligament_authenticator/screens/rdp_connect_dialog.dart';
import 'package:ligament_authenticator/widgets/rdp_target_tile.dart';

/// Мобильная адаптация (390px — базовый iPhone/Android): плитка RDP-цели и
/// диалог подключения обязаны вмещаться без RenderFlex-overflow при
/// максимальном наполнении (длинные имя/endpoint/route, TS-чип с сессиями,
/// обе кнопки в ряд). Тест выставляет вьюпорт 390×844 и ждёт, что макет
/// рисуется без исключений переполнения.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Наихудший по ширине контент плитки.
  final heavyTarget = {
    'name': 'WORKSTATION-MOSCOW-ACCOUNTING-DEPT-01',
    'kind': 'terminal_server',
    'max_sessions': 4,
    'online': true,
    'endpoint': 'ws-accounting-01.corp.local:3389 (agent relay via moscow-gw-1)',
    'route': 'agent-relay-moscow-gw-1-corporate',
  };

  Widget harness(Widget child) => ChangeNotifierProvider<AuthState>.value(
        // AuthState создаём ПОСЛЕ установки моков каналов в setUp.
        value: AuthState(),
        child: MaterialApp(
          home: Scaffold(
            // Как на home_screen: плитки лежат в ListView с padding 16.
            body: ListView(
              padding: const EdgeInsets.all(16),
              children: [child],
            ),
          ),
        ),
      );

  setUp(() {
    debugDefaultTargetPlatformOverride = null;
    // AudioPlayer() в конструкторе AuthState дергает каналы audioplayers —
    // без мока MissingPluginException валит загрузку (см. desktop_confirm_test).
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('xyz.luan/audioplayers'),
      (call) async => call.method == 'create' ? 'test-player' : null,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('xyz.luan/audioplayers.global'),
      (call) async => null,
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('xyz.luan/audioplayers'), null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('xyz.luan/audioplayers.global'), null);
  });

  group('RdpTargetTile @ 390px', () {
    testWidgets('не-Windows: подсказка «RDP — только Windows» + «Экран», без overflow', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(harness(RdpTargetTile(
        target: heavyTarget,
        isRu: true,
      )));
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.text('RDP — только Windows'), findsOneWidget);
      expect(find.text('Экран'), findsOneWidget);
      // Длинный маршрут обрезается многоточием, а не ломает строку чипов.
      expect(find.textContaining('agent-relay-moscow'), findsOneWidget);
    });

    testWidgets('Windows + online: «Подключиться» + «Экран» в ряд, без overflow', (tester) async {
      // Сброс обязателен в теле теста: flutter_test проверяет foundation-
      // инварианты ДО tearDown.
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(harness(RdpTargetTile(
        target: heavyTarget,
        isRu: true,
      )));
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.text('Подключиться'), findsOneWidget);
      expect(find.text('Экран'), findsOneWidget);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('Windows + offline: «Служба Ligament offline», без overflow', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(harness(RdpTargetTile(
        target: {...heavyTarget, 'online': false, 'kind': 'pc'},
        isRu: true,
      )));
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.text('Служба Ligament offline'), findsOneWidget);
      debugDefaultTargetPlatformOverride = null;
    });
  });

  group('RdpConnectDialog @ 390px', () {
    testWidgets('шаг «Грант» с длинным именем цели — без overflow', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final connector = RdpConnectorService();
      addTearDown(connector.dispose);

      await tester.pumpWidget(ChangeNotifierProvider<AuthState>.value(
        value: AuthState(),
        child: MaterialApp(
          home: Scaffold(
            body: RdpConnectDialog(
              connector: connector,
              targetName: 'WORKSTATION-MOSCOW-ACCOUNTING-DEPT-01',
            ),
          ),
        ),
      ));
      // Не pumpAndSettle: спиннер анимируется бесконечно.
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.text('Подключение к рабочему месту'), findsOneWidget);
      expect(find.text('Получение доступа…'), findsOneWidget);
      expect(find.text('Отмена'), findsOneWidget);
    });
  });
}
