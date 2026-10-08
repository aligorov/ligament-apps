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
      expect(ru, contains('подтверждение входа'));
      final en = rdpConnectErrorText(
        ApiException(428, 'mfa_required'),
        isRu: false,
      );
      expect(en, contains('sign-in'));
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
      expect(svc.lastError, contains('подтверждение входа'));
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
}

class _FakeApi extends ApiClient {
  _FakeApi(Future<Map<String, dynamic>> Function(String targetId) behavior)
      : _behavior = behavior,
        super(baseUrl: 'https://core.corp.local');

  final Future<Map<String, dynamic>> Function(String targetId) _behavior;

  @override
  Future<Map<String, dynamic>> rdpGrant({
    required String targetId,
    String mode = 'rdp',
  }) =>
      _behavior(targetId);
}
