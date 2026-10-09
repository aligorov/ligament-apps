import 'package:flutter_test/flutter_test.dart';
import 'package:ligament_authenticator/api/client.dart';
import 'package:ligament_authenticator/services/rdp_service.dart';
import 'dart:async';
import 'dart:io';

/// Этап 2.2: чистая логика RDP-коннектора — разбор ошибок сервера в
/// человеческие тексты (428/403/409/410/502/503), построение URL WS-трубы,
/// best-effort извлечение статуса WS-handshake и машина состояний
/// (grant→failed) на фейковом ApiClient. По образцу ws_backoff_test.dart.
void main() {
  group('rdpConnectErrorText — серверные коды', () {
    test('428 mfa_required → подсказка о свежем подтверждении входа', () {
      final ru = rdpConnectErrorText(
        ApiException(428, 'mfa_required'),
        isRu: true,
      );
      expect(ru, contains('подтверждение'));
      final en = rdpConnectErrorText(
        ApiException(428, 'mfa_required'),
        isRu: false,
      );
      expect(en, contains('second-factor'));
    });

    test('403 target_not_assigned / passkey_required', () {
      expect(
        rdpConnectErrorText(ApiException(403, 'target_not_assigned'),
            isRu: true),
        contains('не назначено'),
      );
      expect(
        rdpConnectErrorText(ApiException(403, 'passkey_required'), isRu: false),
        contains('passkey'),
      );
    });

    test('409 target_busy → сессии заняты', () {
      expect(
        rdpConnectErrorText(ApiException(409, 'target_busy'), isRu: true),
        contains('заняты'),
      );
    });

    test('409 self_connection_prohibited → запрет самоподключения', () {
      expect(
        rdpConnectErrorText(ApiException(409, 'self_connection_prohibited'), isRu: true),
        contains('своему компьютеру запрещено'),
      );
      expect(
        rdpConnectErrorText(ApiException(409, 'self_connection_prohibited'), isRu: false),
        contains('current computer is prohibited'),
      );
    });

    test('403 bridge_disabled → отключен администратором', () {
      expect(
        rdpConnectErrorText(ApiException(403, 'bridge_disabled'), isRu: true),
        contains('отключен администратором'),
      );
    });

    test('400 unsupported_route → служба не подключена', () {
      expect(
        rdpConnectErrorText(ApiException(400, 'unsupported_route'), isRu: true),
        contains('не подключена'),
      );
    });

    test('WS-handshake статусы 410/502/503 из текста ошибки', () {
      final expired = rdpConnectErrorText(
        Exception('WebSocketChannelException: ... status 410 ...'),
        isRu: true,
      );
      expect(expired, contains('гранта истекло'));

      final unreachable = rdpConnectErrorText(
        Exception('WebSocket connection failed: 502 Bad Gateway'),
        isRu: false,
      );
      expect(unreachable, contains('not responding'));

      final relayDown = rdpConnectErrorText(
        Exception('WebSocket connection failed: 503 Service Unavailable'),
        isRu: true,
      );
      expect(relayDown, contains('Релей'));
    });

    test('транспортные ошибки', () {
      expect(
        rdpConnectErrorText(const SocketException('refused'), isRu: true),
        'Нет связи с сервером',
      );
      expect(
        rdpConnectErrorText(TimeoutException('t'), isRu: false),
        'Connection timed out',
      );
    });
  });

  group('rdpWsHandshakeStatus — best effort', () {
    test('находит код статуса в тексте', () {
      expect(rdpWsHandshakeStatus(Exception('failed with 410 Gone')), 410);
      expect(rdpWsHandshakeStatus(Exception('HTTP 502 returned')), 502);
    });

    test('не ловит цифры внутри IP-адресов (10.0.40.12 не даёт 401)', () {
      expect(
          rdpWsHandshakeStatus(Exception('connect to 10.0.40.12:443 failed')),
          isNull);
      expect(rdpWsHandshakeStatus(Exception('connect to 10.0.40.1:443 failed')),
          isNull);
    });

    test('нет кода — null', () {
      expect(
          rdpWsHandshakeStatus(Exception('Connection reset by peer')), isNull);
    });
  });

  group('rdpWsConnectUrl', () {
    test('https-база → wss + путь + ?grant (токен НЕ в query)', () {
      final uri = rdpWsConnectUrl(
        'https://core.corp.local/',
        '11111111-2222-3333-4444-555555555555',
      );
      expect(uri.scheme, 'wss');
      expect(uri.host, 'core.corp.local');
      expect(uri.path, '/api/v1/app/rdp/connect');
      expect(
          uri.queryParameters['grant'], '11111111-2222-3333-4444-555555555555');
      // Грант-токен уходит подпротоколом Sec-WebSocket-Protocol, а не в
      // query: секрет в URL оседает в логах прокси/балансировщика.
      expect(uri.queryParameters.containsKey('grant_token'), isFalse);
      expect(uri.queryParameters.containsKey('token'), isFalse);
    });

    test('хвостовой слэш базы не удваивается', () {
      final uri = rdpWsConnectUrl('https://core.corp.local///', 'g');
      expect(uri.toString(),
          'wss://core.corp.local/api/v1/app/rdp/connect?grant=g');
    });
  });

  group('rdpWsSubprotocols — грант-токен в Sec-WebSocket-Protocol', () {
    test('сервер ожидает список «grant, <hex>» (браузерный паттерн)', () {
      expect(rdpWsSubprotocols('aabbccdd'), ['grant', 'aabbccdd']);
    });
  });

  group('RdpConnectorService — машина состояний', () {
    setUp(() {
      // Guard «только Windows» обходим: логика фаз не зависит от платформы.
      RdpConnectorService.windowsOverride = true;
    });
    tearDown(() {
      RdpConnectorService.windowsOverride = null;
    });

    test('guard платформы: не-Windows — понятный отказ', () async {
      RdpConnectorService.windowsOverride = false;
      final svc = RdpConnectorService();
      await svc.connect(
          api: _FakeApi((_) async => {}),
          baseUrl: 'https://x',
          targetId: 't',
          name: 'n');
      expect(svc.phase, RdpTunnelPhase.failed);
      expect(svc.lastError, contains('Windows'));
    });

    test('ошибка гранта → phase=failed с человеческим текстом', () async {
      final api =
          _FakeApi((targetId) async => throw ApiException(428, 'mfa_required'));
      final svc = RdpConnectorService();
      await svc.connect(
        api: api,
        baseUrl: 'https://core.corp.local',
        targetId: 't1',
        name: 'ws-001',
        isRu: true,
      );
      expect(svc.phase, RdpTunnelPhase.failed);
      expect(svc.lastError, contains('подтверждение'));
      expect(svc.targetName, 'ws-001');
    });

    test('повторный connect из failed разрешён, из busy — нет', () async {
      final api = _FakeApi((_) async => throw ApiException(409, 'target_busy'));
      final svc = RdpConnectorService();
      await svc.connect(
          api: api, baseUrl: 'https://x', targetId: 't', name: 'n');
      expect(svc.phase, RdpTunnelPhase.failed);
      // Из failed новый заход идёт (новый грант/новая попытка).
      await svc.connect(
          api: api, baseUrl: 'https://x', targetId: 't', name: 'n');
      expect(svc.phase, RdpTunnelPhase.failed);
    });

    test('close() из idle безопасен и сбрасывает состояние', () async {
      final svc = RdpConnectorService();
      await svc.close();
      expect(svc.phase, RdpTunnelPhase.idle);
    });
  });

  group('RdpConnectorService.connectBridge — Connector-helper (P1 #3)', () {
    setUp(() {
      // Guard «только Windows» обходим: фазы и мост не зависят от платформы
      // (mstsc реально запустится только на Windows — см. тест «живой мост»).
      RdpConnectorService.windowsOverride = true;
    });
    tearDown(() {
      RdpConnectorService.windowsOverride = null;
    });

    test('guard платформы: не-Windows — понятный отказ', () async {
      RdpConnectorService.windowsOverride = false;
      final svc = RdpConnectorService();
      await svc.connectBridge(
          api: _FakeApi((_) async => {}), grantId: 'g', token: 't');
      expect(svc.phase, RdpTunnelPhase.failed);
      expect(svc.lastError, contains('Windows'));
    });

    test('ошибка bridge-info (409 bridge_already_open) → failed с текстом',
        () async {
      final api = _FakeApi((_) async => {},
          bridgeInfo: (grantId, token) async =>
              throw ApiException(409, 'bridge_already_open'));
      final svc = RdpConnectorService();
      await svc.connectBridge(api: api, grantId: 'g', token: 't', isRu: true);
      expect(svc.phase, RdpTunnelPhase.failed);
      expect(svc.lastError, contains('уже открыт'));
    });

    test('некорректный ответ bridge-info → failed «адрес моста»', () async {
      final api = _FakeApi((_) async => {},
          bridgeInfo: (grantId, token) async => {'host': '', 'port': 0});
      final svc = RdpConnectorService();
      await svc.connectBridge(api: api, grantId: 'g', token: 't', isRu: true);
      expect(svc.phase, RdpTunnelPhase.failed);
      expect(svc.lastError, contains('адрес моста'));
    });

    test('недоступный bridge-порт → транспортная ошибка', () async {
      // Порт, который только что освободился: подключение → ECONNREFUSED.
      final hold = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final deadPort = hold.port;
      await hold.close();
      final api = _FakeApi((_) async => {},
          bridgeInfo: (grantId, token) async =>
              {'host': '127.0.0.1', 'port': deadPort});
      final svc = RdpConnectorService();
      await svc.connectBridge(api: api, grantId: 'g', token: 't', isRu: true);
      expect(svc.phase, RdpTunnelPhase.failed);
      expect(svc.lastError, contains('Нет связи с сервером'));
    });

    test('bridge-порт разорвал соединение после токена → handshake отклонён',
        () async {
      // «Порт» с неверным токеном: принимает и сразу рвёт (как openBridgePort
      // на неверный handshake) — connectBridge обязан увидеть EOF в окне
      // подтверждения и отказаться БЕЗ запуска mstsc.
      final ln = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final sub = ln.listen((s) => s.destroy());
      addTearDown(() async {
        await sub.cancel();
        await ln.close();
      });
      final api = _FakeApi((_) async => {},
          bridgeInfo: (grantId, token) async =>
              {'host': '127.0.0.1', 'port': ln.port});
      final svc = RdpConnectorService();
      await svc.connectBridge(
          api: api, grantId: 'g', token: 't', name: 'ws-002', isRu: true);
      expect(svc.phase, RdpTunnelPhase.failed);
      expect(svc.lastError, contains('отклонил подключение к мосту'));
      expect(svc.targetName, 'ws-002');
    });

    test('живой мост: handshake принят, дальше отказ только на mstsc',
        () async {
      RdpConnectorService.startClientOverride =
          ({required host, required port, tempRdpFile}) async => null;
      addTearDown(() => RdpConnectorService.startClientOverride = null);

      // «Порт» с верным поведением: принимает и держит соединение (токен
      // принят). Запуск RDP-клиента падает (override null) — сессия обязана
      // дожить до фазы launching и упасть именно на запуске клиента, а не на
      // handshake-окне.
      final ln = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final conns = <Socket>[];
      final sub = ln.listen((s) {
        conns.add(s);
        s.listen((_) {}, onError: (_) {});
      });
      addTearDown(() async {
        await sub.cancel();
        for (final c in conns) {
          c.destroy();
        }
        await ln.close();
      });
      final api = _FakeApi((_) async => {},
          bridgeInfo: (grantId, token) async =>
              {'host': '127.0.0.1', 'port': ln.port});
      final svc = RdpConnectorService();
      await svc.connectBridge(api: api, grantId: 'g', token: 't', isRu: true);
      expect(svc.phase, RdpTunnelPhase.failed);
      expect(svc.lastError, contains(Platform.isMacOS ? 'Windows App' : 'mstsc'));
    }, timeout: const Timeout(Duration(seconds: 30)));
  });

  group('rdpBridgeEndpoint — разбор bridge-info', () {
    test('валидный {host, port}', () {
      final ep = rdpBridgeEndpoint({'host': 'core.corp.local', 'port': 40123});
      expect(ep, isNotNull);
      expect(ep!.$1, 'core.corp.local');
      expect(ep.$2, 40123);
    });

    test('некорректные ответы → null', () {
      expect(rdpBridgeEndpoint({}), isNull);
      expect(rdpBridgeEndpoint({'host': '', 'port': 1234}), isNull);
      expect(rdpBridgeEndpoint({'host': 'h', 'port': 0}), isNull);
      expect(rdpBridgeEndpoint({'host': 'h', 'port': 65536}), isNull);
      expect(rdpBridgeEndpoint({'host': 'h', 'port': 'nonsense'}), isNull);
      expect(rdpBridgeEndpoint({'port': 1234}), isNull);
      expect(rdpBridgeEndpoint({'host': 'h'}), isNull);
    });
  });
}

class _FakeApi extends ApiClient {
  _FakeApi(
    Future<Map<String, dynamic>> Function(String targetId) behavior, {
    Future<Map<String, dynamic>> Function(String grantId, String token)?
        bridgeInfo,
  })  : _behavior = behavior,
        _bridgeInfo = bridgeInfo,
        super(baseUrl: 'https://core.corp.local');

  final Future<Map<String, dynamic>> Function(String targetId) _behavior;
  final Future<Map<String, dynamic>> Function(String grantId, String token)?
      _bridgeInfo;

  @override
  Future<Map<String, dynamic>> rdpGrant({
    required String targetId,
    String mode = 'rdp',
    String? code,
    String? actionId,
    String? sourceInstanceId,
    String? attemptId,
    List<String>? clientLocalIps,
  }) =>
      _behavior(targetId);

  @override
  Future<Map<String, dynamic>> rdpBridgeInfo({
    required String grantId,
    required String token,
  }) =>
      _bridgeInfo?.call(grantId, token) ??
      super.rdpBridgeInfo(grantId: grantId, token: token);
}
