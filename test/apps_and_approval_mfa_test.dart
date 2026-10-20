import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ligament_authenticator/screens/approval_modal.dart';
import 'package:ligament_authenticator/screens/apps_screen.dart';
import 'package:ligament_authenticator/services/auth_state.dart';
import 'package:ligament_authenticator/services/rdp_service.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MockAuthState extends ChangeNotifier implements AuthState {
  @override
  String localeCode = 'ru';

  @override
  bool isRu = true;

  @override
  final RdpConnectorService rdp = RdpConnectorService();

  @override
  bool rdpFeatureAvailable = true;

  @override
  List<Map<String, dynamic>> rdpTargets = [
    {
      'id': '00000000-0000-0000-0000-000000000001',
      'name': 'Бухгалтерия PC-1',
      'kind': 'pc',
      'online': true,
      'route': 'relay',
    },
    {
      'id': '00000000-0000-0000-0000-000000000002',
      'name': 'Сервер 1C Terminal',
      'kind': 'terminal_server',
      'online': false,
      'route': 'agent',
    },
  ];

  @override
  List<Map<String, dynamic>> allowedApps = [
    {
      'name': 'Корпоративный портал',
      'launch_url': 'https://portal.corp.local',
    },
    {
      'name': '1С:Предприятие Web',
      'launch_url': 'https://1c.corp.local/base',
    },
  ];

  String? lastSubmittedCode;
  bool? lastSubmittedPasskey;
  bool? lastApprove;
  String? lastSelectedNumberMatch;

  @override
  Map<String, dynamic>? activePrompt;

  @override
  Future<void> submitDecision({
    required String challengeId,
    required bool approve,
    String? selectedNumberMatch,
    String? code,
    bool? passkey,
  }) async {
    lastApprove = approve;
    lastSubmittedCode = code;
    lastSubmittedPasskey = passkey;
    lastSelectedNumberMatch = selectedNumberMatch;
  }

  @override
  Future<void> loadAllowedApps() async {}

  @override
  Future<void> loadRdpTargets() async {}

  @override
  Future<void> loadLinkHosts() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Widget buildTestApp({required Widget child, required MockAuthState auth}) {
    return ChangeNotifierProvider<AuthState>.value(
      value: auth,
      child: MaterialApp(
        home: child,
      ),
    );
  }

  group('ApprovalModal: Passkey и TOTP', () {
    testWidgets('рендерит кнопку Passkey и кнопку вызова ввода TOTP',
        (tester) async {
      final auth = MockAuthState();
      final prompt = {
        'challenge_id': 'ch-123',
        'who': 'ivanov',
        'service': 'VPN Corporate',
        'ip': '192.168.1.10',
        'expires_in_seconds': 60,
      };

      await tester.pumpWidget(buildTestApp(
        child: ApprovalModal(prompt: prompt),
        auth: auth,
      ));
      await tester.pump();

      // Проверяем наличие кнопки Passkey
      expect(find.text('🔑 Подтвердить через Passkey'), findsOneWidget);
      // Проверяем наличие ссылки/кнопки для ввода TOTP
      expect(find.text('Или подтвердить кодом TOTP'), findsOneWidget);

      // Раскрываем окно для ввода TOTP
      await tester.tap(find.text('Или подтвердить кодом TOTP'));
      await tester.pump();

      // Проверяем, что появилось поле ввода TOTP кода
      expect(find.text('Введите 6-значный TOTP код из приложения:'),
          findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('Ввод'), findsOneWidget);

      // Вводим код и нажимаем Ввод
      await tester.enterText(find.byType(TextField), '123456');
      await tester.pump();
      await tester.tap(find.text('Ввод'));
      await tester.pump();

      // Проверяем, что в submitDecision ушел введенный код TOTP
      expect(auth.lastApprove, isTrue);
      expect(auth.lastSubmittedCode, equals('123456'));
    });

    testWidgets('нажатие кнопки Passkey отправляет passkey: true',
        (tester) async {
      final auth = MockAuthState();
      final prompt = {
        'challenge_id': 'ch-456',
        'who': 'petrov',
        'service': 'Corporate SSO',
        'ip': '10.0.0.5',
        'expires_in_seconds': 60,
      };

      await tester.pumpWidget(buildTestApp(
        child: ApprovalModal(prompt: prompt),
        auth: auth,
      ));
      await tester.pump();

      await tester.tap(find.text('🔑 Подтвердить через Passkey'));
      await tester.pump();

      expect(auth.lastApprove, isTrue);
      expect(auth.lastSubmittedPasskey, isTrue);
    });
  });

  group('ApprovalModal: Number Matching без предвыбора (A-9)', () {
    // Тесты исполняются на десктоп-хосте (macOS) → _isDesktop == true:
    // проверяем именно ту ветку, где раньше правильное число
    // предвыбиралось и «Принять» уходило без сверки с экраном входа.
    testWidgets('«Принять» без выбора числа блокируется, решение не уходит',
        (tester) async {
      final auth = MockAuthState();
      final prompt = {
        'challenge_id': 'ch-nm1',
        'who': 'sidorov',
        'service': 'Windows RDP (WS-001)',
        'ip': '192.168.1.10',
        'number_match': '42',
        'expires_in_seconds': 60,
      };

      await tester.pumpWidget(
          buildTestApp(child: ApprovalModal(prompt: prompt), auth: auth));
      await tester.pump();

      // Модал с number-match выше вьюпорта теста — прокручиваем к кнопке.
      await tester.ensureVisible(find.text('Принять'));
      await tester.pump();
      await tester.tap(find.text('Принять'));
      await tester.pump();

      expect(find.text('Выберите верный номер, показанный на экране входа'),
          findsOneWidget);
      expect(auth.lastApprove, isNull); // submitDecision не вызывался
    });

    testWidgets('явный выбор числа пользователем разблокирует подтверждение',
        (tester) async {
      final auth = MockAuthState();
      final prompt = {
        'challenge_id': 'ch-nm2',
        'who': 'sidorov',
        'service': 'Windows RDP (WS-001)',
        'ip': '192.168.1.10',
        'number_match': '42',
        'expires_in_seconds': 60,
      };

      await tester.pumpWidget(
          buildTestApp(child: ApprovalModal(prompt: prompt), auth: auth));
      await tester.pump();

      // Пользователь сверил число с экраном входа и выбрал его сам.
      await tester.tap(find.text('42'));
      await tester.pump();
      await tester.ensureVisible(find.text('Принять'));
      await tester.pump();
      await tester.tap(find.text('Принять'));
      await tester.pump();

      expect(auth.lastApprove, isTrue);
      expect(auth.lastSelectedNumberMatch, '42');
    });
  });

  group('AppsScreen: Рабочие места + SSO Приложения', () {
    testWidgets(
        'отображает рабочие места и SSO-приложения, фильтрует по поиску и чипам',
        (tester) async {
      final auth = MockAuthState();

      await tester.pumpWidget(buildTestApp(
        child: const AppsScreen(),
        auth: auth,
      ));
      await tester.pumpAndSettle();

      // Проверяем заголовки секций
      expect(find.text('Мои рабочие места'), findsOneWidget);
      expect(find.text('Корпоративные приложения (SSO)'), findsOneWidget);

      // Проверяем наличие элементов
      expect(find.text('Бухгалтерия PC-1'), findsOneWidget);
      expect(find.text('Сервер 1C Terminal'), findsOneWidget);
      expect(find.text('Корпоративный портал'), findsOneWidget);
      expect(find.text('1С:Предприятие Web'), findsOneWidget);

      // Проверяем наличие фильтр-чипов
      expect(find.text('Все (4)'), findsOneWidget);
      expect(find.text('Рабочие места (2)'), findsOneWidget);
      expect(find.text('Приложения (2)'), findsOneWidget);

      // Фильтруем чипом: только «Рабочие места»
      await tester.tap(find.text('Рабочие места (2)'));
      await tester.pumpAndSettle();

      expect(find.text('Бухгалтерия PC-1'), findsOneWidget);
      expect(find.text('Корпоративный портал'), findsNothing);

      // Фильтруем чипом: только «Приложения»
      await tester.tap(find.text('Приложения (2)'));
      await tester.pumpAndSettle();

      expect(find.text('Бухгалтерия PC-1'), findsNothing);
      expect(find.text('Корпоративный портал'), findsOneWidget);

      // Сбрасываем на «Все»
      await tester.tap(find.text('Все (4)'));
      await tester.pumpAndSettle();

      // Проверяем поиск
      final searchField = find.byType(TextField);
      expect(searchField, findsOneWidget);

      await tester.enterText(searchField, 'Бухгалтерия');
      await tester.pumpAndSettle();

      expect(find.text('Бухгалтерия PC-1'), findsOneWidget);
      expect(find.text('Сервер 1C Terminal'), findsNothing);
      expect(find.text('Корпоративный портал'), findsNothing);
    });
  });
}
