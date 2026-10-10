import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:ligament_authenticator/services/auth_state.dart';
import 'package:ligament_authenticator/services/rdp_endpoint_config_service.dart';
import 'package:ligament_authenticator/widgets/rdp_service_settings_card.dart';

class FakeRdpEndpointConfigService extends RdpEndpointConfigService {
  FakeRdpEndpointConfigService({
    this.status = RdpEndpointServiceStatus.stopped,
    this.hostname = 'WORKSTATION-TEST',
    this.configSuccess = true,
  });

  RdpEndpointServiceStatus status;
  final String hostname;
  final bool configSuccess;
  String? lastConfiguredKey;
  String? lastServerUrl;

  @override
  bool get isWindows => true;

  @override
  String get localHostname => hostname;

  @override
  Future<RdpEndpointServiceStatus> getServiceStatus() async {
    return status;
  }

  @override
  Future<bool> configureEndpointService({
    required String agentKey,
    String? serverUrl,
  }) async {
    lastConfiguredKey = agentKey;
    lastServerUrl = serverUrl;
    if (configSuccess) {
      status = RdpEndpointServiceStatus.running;
      return true;
    }
    return false;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget buildTestWidget({
    required FakeRdpEndpointConfigService fakeService,
    AuthState? auth,
  }) {
    final authState = auth ?? AuthState();
    return MaterialApp(
      home: Scaffold(
        body: ChangeNotifierProvider<AuthState>.value(
          value: authState,
          child: RdpServiceSettingsCard(
            configService: fakeService,
          ),
        ),
      ),
    );
  }

  testWidgets('RdpServiceSettingsCard: отображает статус, имя ПК и скрытое поле ключа',
      (tester) async {
    final fakeService = FakeRdpEndpointConfigService(
      status: RdpEndpointServiceStatus.stopped,
      hostname: 'PC-BUH-01',
    );

    await tester.pumpWidget(buildTestWidget(fakeService: fakeService));
    await tester.pumpAndSettle();

    expect(find.text('Служба доступа к этому ПК (Agent)'), findsOneWidget);
    expect(find.text('PC-BUH-01'), findsOneWidget);
    expect(find.text('Остановлена'), findsOneWidget);

    final keyFieldFinder = find.byKey(const Key('rdpAgentKeyField'));
    expect(keyFieldFinder, findsOneWidget);
    final textField = tester.widget<TextField>(keyFieldFinder);
    expect(textField.obscureText, isTrue);
  });

  testWidgets('RdpServiceSettingsCard: пустой ключ показывает ошибку',
      (tester) async {
    final fakeService = FakeRdpEndpointConfigService();

    await tester.pumpWidget(buildTestWidget(fakeService: fakeService));
    await tester.pumpAndSettle();

    final btnFinder = find.byKey(const Key('rdpConnectThisPcBtn'));
    await tester.tap(btnFinder);
    await tester.pumpAndSettle();

    expect(find.text('Введите ключ подключения'), findsOneWidget);
    expect(fakeService.lastConfiguredKey, isNull);
  });

  testWidgets('RdpServiceSettingsCard: успешная настройка очищает ключ и переключает статус',
      (tester) async {
    final fakeService = FakeRdpEndpointConfigService(
      status: RdpEndpointServiceStatus.stopped,
      configSuccess: true,
    );

    await tester.pumpWidget(buildTestWidget(fakeService: fakeService));
    await tester.pumpAndSettle();

    final keyFieldFinder = find.byKey(const Key('rdpAgentKeyField'));
    await tester.enterText(keyFieldFinder, 'secret-agent-key-12345');
    await tester.pumpAndSettle();

    final btnFinder = find.byKey(const Key('rdpConnectThisPcBtn'));
    await tester.tap(btnFinder);
    await tester.pump(); // начался запрос

    // Ждем завершения таймера Future.delayed(2s)
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();

    expect(fakeService.lastConfiguredKey, 'secret-agent-key-12345');
    // Поле ввода должно быть очищено для безопасности
    final textField = tester.widget<TextField>(keyFieldFinder);
    expect(textField.controller?.text, isEmpty);

    expect(find.text('Служба успешно настроена'), findsOneWidget);
    expect(find.text('Служба запущена'), findsOneWidget);
  });

  testWidgets('RdpServiceSettingsCard: отказ настройки показывает сообщение об ошибке прав',
      (tester) async {
    final fakeService = FakeRdpEndpointConfigService(
      status: RdpEndpointServiceStatus.stopped,
      configSuccess: false,
    );

    await tester.pumpWidget(buildTestWidget(fakeService: fakeService));
    await tester.pumpAndSettle();

    final keyFieldFinder = find.byKey(const Key('rdpAgentKeyField'));
    await tester.enterText(keyFieldFinder, 'invalid-or-denied-key');
    await tester.pumpAndSettle();

    final btnFinder = find.byKey(const Key('rdpConnectThisPcBtn'));
    await tester.tap(btnFinder);
    await tester.pumpAndSettle();

    expect(find.text('Ошибка настройки (требуются права администратора)'), findsOneWidget);
  });
}
