import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ligament_authenticator/api/client.dart';
import 'package:ligament_authenticator/services/auth_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Этап D «умный 2FA»: 403 desktop_confirm_forbidden на approve возвращает
/// карточку подтверждения (снимок activePrompt + вывод id из resolved),
/// модал не съедается polling-тиком, ошибка уходит в UI с переводом
/// errDesktopConfirm. Иные ошибки решения — прежнее поведение.
///
/// ЛОВУШКИ прошлого прогона учтены:
/// - HttpClient мокается НЕ через HttpOverrides (геттер global изъят из
///   SDK, работает только сеттер) — поднимается настоящий HttpServer на
///   loopback, ApiClient ходит по реальному сокету;
/// - каналы audioplayers замоканы (AlertService создаёт плеер в конструкторе
///   AuthState);
/// - обычные test(), не testWidgets: реальный сетевой I/O в FakeAsync
///   testWidgets не дождаться.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // ЛОВУШКА прошлого прогона: initialized-байндинг подменяет HttpClient —
  // все запросы получают 400 без сети. Геттер HttpOverrides.global из SDK
  // изъят, сеттер работает: сбрасываем подмену, чтобы ApiClient ходил по
  // настоящему сокету в мок-сервер.
  HttpOverrides.global = null;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // AudioPlayer() создаётся в конструкторе AuthState -> дергает каналы.
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

  // Мок 2fa-сервера на реальном сокете: ответы по методу+пути.
  Future<HttpServer> startMock(
    Future<(int, String)> Function(String method, String path) handler,
  ) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      await utf8.decoder.bind(req).join(); // тело вычитываем до ответа
      final (status, body) = await handler(req.method, req.uri.path);
      req.response.statusCode = status;
      req.response.headers.contentType = ContentType.json;
      req.response.write(body);
      await req.response.close();
    });
    return server;
  }

  Map<String, dynamic> challenge(String id) => {
        'id': id,
        'type': 'push',
        'status': 'pending',
        'created_at': '2026-10-06T10:00:00Z',
        'expires_in_seconds': 120,
        'metadata': {
          'username': 'ivanov',
          'client_ip': '127.0.0.1',
          'host': 'WS-001',
          'service': 'Windows RDP (WS-001)',
        },
      };

  test('403 desktop_confirm_forbidden: карточка возвращается, переживает polling-тик, повторный approve проходит', () async {
    var decisionCalls = 0;
    final server = await startMock((method, path) async {
      if (method == 'POST' &&
          path.startsWith('/api/v1/app/challenges/') &&
          path.endsWith('/decision')) {
        decisionCalls++;
        if (decisionCalls == 1) {
          return (403, '{"error":"desktop_confirm_forbidden"}');
        }
        return (200, '{}');
      }
      if (method == 'GET' && path == '/api/v1/app/challenges/pending') {
        // Челлендж жив, пока решение не принято успешно.
        return (200, decisionCalls >= 2 ? '[]' : jsonEncode([challenge('ch-1')]));
      }
      if (method == 'GET' && path == '/api/v1/app/me/history') {
        return (200, '[]');
      }
      return (404, '{"error":"unmocked $method $path"}');
    });
    addTearDown(() => server.close());

    final auth = AuthState();
    auth.api = ApiClient(baseUrl: 'http://127.0.0.1:${server.port}', token: 'tok');
    auth.token = 'tok';
    auth.currentUser = {'username': 'ivanov', 'display_name': 'Иван'};
    auth.activePrompt = {
      'challenge_id': 'ch-1',
      'who': 'ivanov',
      'number_match': '42',
      'expires_in_seconds': 120,
    };

    // Первая попытка — сервер запрещает подтверждение с того же ПК.
    await expectLater(
      auth.submitDecision(challengeId: 'ch-1', approve: true, selectedNumberMatch: '42'),
      throwsA(
        isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', 403)
            .having((e) => e.code, 'code', 'desktop_confirm_forbidden'),
      ),
    );
    expect(decisionCalls, 1);

    // Карточка ВОЗВРАЩАЕТСЯ: снимок до закрытия, с number_match.
    expect(auth.activePrompt, isNotNull);
    expect(auth.activePrompt?['challenge_id'], 'ch-1');
    expect(auth.activePrompt?['number_match'], '42');

    // id вынут из _resolvedChallengeIds: polling-тик видит челлендж живым
    // и НЕ гасит модалку (иначе она бы закрылась «все челленджи закрыты»).
    await auth.loadPendingChallenges();
    expect(auth.activePrompt?['challenge_id'], 'ch-1');

    // Повторная попытка после возврата карточки проходит, модал закрывается.
    await auth.submitDecision(challengeId: 'ch-1', approve: true, selectedNumberMatch: '42');
    expect(decisionCalls, 2);
    expect(auth.activePrompt, isNull);

    // Ошибка переводится в сообщении для модала (ветка errDesktopConfirm).
    final ex = ApiException(403, 'desktop_confirm_forbidden');
    expect(ex.toString(), contains('desktop_confirm_forbidden'));
  });

  test('иная ошибка approve (409 number_match_mismatch) — прежнее поведение: карточка НЕ возвращается', () async {
    final server = await startMock((method, path) async {
      if (method == 'POST' &&
          path.startsWith('/api/v1/app/challenges/') &&
          path.endsWith('/decision')) {
        return (409, '{"error":"number_match_mismatch"}');
      }
      if (method == 'GET' && path == '/api/v1/app/challenges/pending') {
        return (200, jsonEncode([challenge('ch-9')]));
      }
      if (method == 'GET' && path == '/api/v1/app/me/history') {
        return (200, '[]');
      }
      return (404, '{"error":"unmocked $method $path"}');
    });
    addTearDown(() => server.close());

    final auth = AuthState();
    auth.api = ApiClient(baseUrl: 'http://127.0.0.1:${server.port}', token: 'tok');
    auth.token = 'tok';
    auth.currentUser = {'username': 'ivanov'};
    auth.activePrompt = {
      'challenge_id': 'ch-9',
      'who': 'ivanov',
      'number_match': '42',
      'expires_in_seconds': 120,
    };

    await expectLater(
      auth.submitDecision(challengeId: 'ch-9', approve: true, selectedNumberMatch: '99'),
      throwsA(
        isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', 409)
            .having((e) => e.code, 'code', 'number_match_mismatch'),
      ),
    );

    // Карточка не возвращается (прежнее поведение), и polling не воскрешает:
    // id остался в resolved, челлендж фильтруется из pending.
    expect(auth.activePrompt, isNull);
    await auth.loadPendingChallenges();
    expect(auth.activePrompt, isNull);
    expect(auth.pendingChallenges, isEmpty);
  });
}
