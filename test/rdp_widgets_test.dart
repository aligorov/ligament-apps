import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:ligament_authenticator/services/auth_state.dart';
import 'package:ligament_authenticator/services/rdp_service.dart';
import 'package:ligament_authenticator/screens/rdp_connect_dialog.dart';
import 'package:ligament_authenticator/widgets/rdp_target_tile.dart';
import 'package:ligament_authenticator/widgets/rdp_mfa_dialog.dart';

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
    'kind': 'pc',
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
    testWidgets('не-десктоп: подсказка «RDP — Windows / macOS» + «Console», без overflow', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
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
      expect(find.text('RDP — Windows / macOS'), findsOneWidget);
      expect(find.text('Console'), findsOneWidget);
      // Длинный маршрут обрезается многоточием, а не ломает строку чипов.
      expect(find.textContaining('agent-relay-moscow'), findsOneWidget);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('macOS + online: «Подключить» + «Console» в ряд, без overflow', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
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
      expect(find.text('Подключить'), findsOneWidget);
      expect(find.text('Console'), findsOneWidget);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('Windows + online: «Подключить» + «Console» в ряд, без overflow', (tester) async {
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
      expect(find.text('Подключить'), findsOneWidget);
      expect(find.text('Console'), findsOneWidget);
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

    testWidgets('Windows + is_self: бейдж «Текущий ПК» и кнопка «Текущий компьютер», без overflow', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(harness(RdpTargetTile(
        target: {...heavyTarget, 'online': true, 'is_self': true, 'rdp_available': false, 'rdp_reason': 'self_connection_prohibited'},
        isRu: true,
      )));
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.text('Текущий ПК'), findsOneWidget);
      expect(find.text('Текущий компьютер'), findsOneWidget);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('Windows + direct terminal_server offline: «Сервер недоступен», без overflow', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(harness(RdpTargetTile(
        target: {
          'name': 'term01',
          'kind': 'terminal_server',
          'max_sessions': 50,
          'online': false,
          'route': 'direct',
          'rdp_available': false,
          'rdp_reason': 'target_offline',
        },
        isRu: true,
      )));
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.text('Сервер недоступен'), findsOneWidget);
      expect(find.text('Console'), findsNothing);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('Windows + terminal_server online: только «Подключиться», «Console» скрыт', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(harness(RdpTargetTile(
        target: {
          'name': 'TS-CLUSTER-01',
          'kind': 'terminal_server',
          'max_sessions': 16,
          'online': true,
          'endpoint': '10.10.20.103:3389 (direct)',
          'route': 'direct',
        },
        isRu: true,
      )));
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.text('Подключиться'), findsOneWidget);
      expect(find.text('Console'), findsNothing);
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

    testWidgets('RdpMfaDialog: отображает кнопку Passkey и подтверждает по клику',
        (tester) async {
      final fakeAuth = _FakeLocalAuth();
      RdpMfaResult? result;

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => ElevatedButton(
              onPressed: () async {
                result = await showRdpMfaDialog(
                  ctx,
                  isRu: true,
                  localAuth: fakeAuth,
                );
              },
              child: const Text('Открыть'),
            ),
          ),
        ),
      ));

      await tester.tap(find.text('Открыть'));
      await tester.pumpAndSettle();

      expect(find.text('🔑 Подтвердить через Passkey'), findsOneWidget);
      expect(find.text('Подтвердить кодом'), findsOneWidget);

      await tester.tap(find.text('🔑 Подтвердить через Passkey'));
      await tester.pumpAndSettle();

      expect(fakeAuth.authenticateCalled, isTrue);
      expect(result?.passkey, isTrue);
      expect(result?.code, isNull);
    });

    testWidgets('RdpMfaDialog: позволяет ввести 6-значный TOTP код',
        (tester) async {
      final fakeAuth = _FakeLocalAuth();
      RdpMfaResult? result;

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => ElevatedButton(
              onPressed: () async {
                result = await showRdpMfaDialog(
                  ctx,
                  isRu: true,
                  localAuth: fakeAuth,
                );
              },
              child: const Text('Открыть'),
            ),
          ),
        ),
      ));

      await tester.tap(find.text('Открыть'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '654321');
      await tester.tap(find.text('Подтвердить кодом'));
      await tester.pumpAndSettle();

      expect(fakeAuth.authenticateCalled, isFalse);
      expect(result?.passkey, isFalse);
      expect(result?.code, equals('654321'));
    });
  });
}

class _FakeLocalAuth {
  bool authenticateCalled = false;
  Future<bool> isDeviceSupported() async => true;
  Future<bool> authenticate({required String localizedReason, dynamic options}) async {
    authenticateCalled = true;
    return true;
  }
}
