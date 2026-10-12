import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ligament_authenticator/services/local_detect_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Этап D «умный 2FA»: контракт локального детекта (127.0.0.1:8757) и
/// поведение живого слушателя. Тесты сокета — на реальном HttpClient
/// (HttpOverrides не используется и не нужен).
void main() {
  group('localDetectResponse — контракт (чистая функция)', () {
    test('GET /ligament без Origin (CLI) → 200 с телом {"v":1,"device_id":...}',
        () {
      final r = localDetectResponse('GET', '/ligament', 'uuid-1234');
      expect(r.status, 200);
      final data = jsonDecode(r.body) as Map<String, dynamic>;
      expect(data['v'], 1);
      expect(data['device_id'], 'uuid-1234');
      expect(data.keys.toSet(), {'v', 'device_id'});
      // A-8: без Origin CORS-заголовки не нужны вовсе
      expect(r.headers.containsKey('Access-Control-Allow-Origin'), isFalse);
    });

    test('GET /ligament — Cache-Control: no-store всегда присутствует', () {
      final r = localDetectResponse('GET', '/ligament', 'x');
      expect(r.headers['Cache-Control'], 'no-store');
      expect(r.headers['Content-Type'], contains('application/json'));
    });

    test('A-8: GET /ligament с Origin сервера → 200 + ACAO эхом (не *)', () {
      final r = localDetectResponse(
        'GET',
        '/ligament',
        'x',
        origin: 'https://2fa.corp.local',
        serverOrigin: 'https://2fa.corp.local',
      );
      expect(r.status, 200);
      expect(
          r.headers['Access-Control-Allow-Origin'], 'https://2fa.corp.local');
      expect(r.headers['Access-Control-Allow-Origin'], isNot('*'));
    });

    test('A-8: GET /ligament с чужим Origin → 403 без тела и без CORS', () {
      final r = localDetectResponse(
        'GET',
        '/ligament',
        'x',
        origin: 'https://evil.example.com',
        serverOrigin: 'https://2fa.corp.local',
      );
      expect(r.status, 403);
      expect(r.body, isEmpty);
      expect(r.headers.containsKey('Access-Control-Allow-Origin'), isFalse);
    });

    test('A-8: localhost-Origin и literal "null" проходят', () {
      expect(
        localDetectResponse('GET', '/ligament', 'x',
                origin: 'http://localhost:3000')
            .status,
        200,
      );
      expect(
        localDetectResponse('GET', '/ligament', 'x',
                origin: 'http://127.0.0.1:8080')
            .status,
        200,
      );
      expect(
        localDetectResponse('GET', '/ligament', 'x', origin: 'null').status,
        200,
      );
    });

    test('A-8: origin сервера без порта совпадает с явным портом по умолчанию',
        () {
      final r = localDetectResponse(
        'GET',
        '/ligament',
        'x',
        origin: 'https://2fa.corp.local:443',
        serverOrigin: 'https://2fa.corp.local',
      );
      expect(r.status, 200);
    });

    test('A-8: другой порт того же хоста — чужой origin → 403', () {
      final r = localDetectResponse(
        'GET',
        '/ligament',
        'x',
        origin: 'https://2fa.corp.local:8443',
        serverOrigin: 'https://2fa.corp.local',
      );
      expect(r.status, 403);
    });

    test(
        'OPTIONS /ligament → 204 без Access-Control-Allow-Private-Network (A-2)',
        () {
      final r = localDetectResponse('OPTIONS', '/ligament', 'x');
      expect(r.status, 204);
      expect(r.body, isEmpty);
      // CORS полностью убран: никаких * и Private-Network
      expect(r.headers.containsKey('Access-Control-Allow-Origin'), isFalse);
      expect(r.headers.containsKey('Access-Control-Allow-Private-Network'),
          isFalse);
    });

    test('OPTIONS /ligament с Origin сервера → 204 + эхо ACAO', () {
      final r = localDetectResponse(
        'OPTIONS',
        '/ligament',
        'x',
        origin: 'https://2fa.corp.local',
        serverOrigin: 'https://2fa.corp.local',
      );
      expect(r.status, 204);
      expect(
          r.headers['Access-Control-Allow-Origin'], 'https://2fa.corp.local');
      expect(r.headers['Access-Control-Allow-Methods']!, contains('GET'));
      expect(r.headers.containsKey('Access-Control-Allow-Private-Network'),
          isFalse);
    });

    test('OPTIONS /ligament с чужим Origin → 403', () {
      final r = localDetectResponse(
        'OPTIONS',
        '/ligament',
        'x',
        origin: 'https://evil.example.com',
        serverOrigin: 'https://2fa.corp.local',
      );
      expect(r.status, 403);
    });

    test('прочие методы на /ligament → 404', () {
      expect(localDetectResponse('POST', '/ligament', 'x').status, 404);
      expect(localDetectResponse('HEAD', '/ligament', 'x').status, 404);
      expect(localDetectResponse('PUT', '/ligament', 'x').status, 404);
    });

    test('чужие пути → 404 (отвечает только /ligament)', () {
      expect(localDetectResponse('GET', '/', 'x').status, 404);
      expect(localDetectResponse('GET', '/ligamentx', 'x').status, 404);
      expect(localDetectResponse('OPTIONS', '/other', 'x').status, 404);
    });

    test('device_id JSON-экранируется — тело остаётся валидным JSON', () {
      final r = localDetectResponse('GET', '/ligament', 'id"with\\special');
      final data = jsonDecode(r.body) as Map<String, dynamic>;
      expect(data['device_id'], 'id"with\\special');
    });

    test('версия контракта v — целое число, а не строка', () {
      final r = localDetectResponse('GET', '/ligament', 'u');
      expect(jsonDecode(r.body)['v'], isA<int>());
    });
  });

  group('autoshareAuthorized — A-2: Origin + wake-токен (чистая функция)', () {
    final token = 'a' * 64;

    test('нативный вызов без Origin с верным токеном → разрешён', () {
      expect(autoshareAuthorized(null, token, token), isTrue);
      expect(autoshareAuthorized('null', token, token), isTrue);
      expect(
          autoshareAuthorized('http://localhost:5173', token, token), isTrue);
      expect(
          autoshareAuthorized('http://127.0.0.1:8080', token, token), isTrue);
    });

    test('браузерные Origin запрещены — даже origin сервера', () {
      expect(
          autoshareAuthorized('https://2fa.corp.local', token, token), isFalse);
      expect(autoshareAuthorized('https://evil.example.com', token, token),
          isFalse);
    });

    test('без токена / с чужим токеном / без ожидаемого — отказ', () {
      expect(autoshareAuthorized(null, null, token), isFalse);
      expect(autoshareAuthorized(null, 'b' * 64, token), isFalse);
      expect(autoshareAuthorized(null, token, null), isFalse);
      expect(autoshareAuthorized(null, token.substring(0, 63), token), isFalse);
    });

    test('верный токен при локальном Origin → разрешён', () {
      expect(
          autoshareAuthorized('http://localhost:3000', token, token), isTrue);
    });
  });

  group('LocalDetectService — живой сокет на 127.0.0.1:8757', () {
    // Живые тесты биндят контрактный порт. Если его занимает внешний
    // процесс (например, запущенное приложение на машине разработчика) —
    // пропускаем, а не падаем: на CI порт свободен.
    /// true — контрактный порт занят внешним процессом (запущенное
    /// приложение на машине разработчика); тест пропускается.
    Future<bool> foreignPortBusy() async {
      try {
        final probe = await HttpServer.bind(
          InternetAddress.loopbackIPv4,
          kLocalDetectPort,
        );
        await probe.close();
        return false;
      } catch (_) {
        return true;
      }
    }

    test('контракт через реальный HttpClient (GET/OPTIONS/404, server_url)',
        () async {
      if (await foreignPortBusy()) {
        markTestSkipped(
            'порт 8757 занят внешним процессом (запущено приложение?)');
        return;
      }
      // flutter test исполняется на десктоп-хосте CI (ubuntu/macos/windows).
      expect(LocalDetectService.isSupported, isTrue);
      SharedPreferences.setMockInitialValues(
          {'server_url': 'https://2fa.corp.local'});

      final svc = LocalDetectService();
      addTearDown(svc.stop);
      await svc.start('11111111-2222-3333-4444-555555555555');
      expect(svc.isRunning, isTrue);

      final client = HttpClient();
      addTearDown(client.close);

      // GET без Origin → 200 + no-store + точное тело контракта, без ACAO
      final get = await (await client
              .getUrl(Uri.parse('http://127.0.0.1:8757/ligament')))
          .close();
      expect(get.statusCode, 200);
      expect(get.headers.value('Access-Control-Allow-Origin'), isNull);
      expect(get.headers.value(HttpHeaders.cacheControlHeader), 'no-store');
      final body = jsonDecode(await get.transform(utf8.decoder).join())
          as Map<String, dynamic>;
      expect(body['v'], 1);
      expect(body['device_id'], '11111111-2222-3333-4444-555555555555');

      // GET с Origin сервера → 200 + эхо ACAO
      final getOrigin = await client.openUrl(
          'GET', Uri.parse('http://127.0.0.1:8757/ligament'));
      getOrigin.headers.set('origin', 'https://2fa.corp.local');
      final getOriginRes = await getOrigin.close();
      expect(getOriginRes.statusCode, 200);
      expect(getOriginRes.headers.value('Access-Control-Allow-Origin'),
          'https://2fa.corp.local');

      // GET с чужим Origin → 403 без тела
      final getEvil = await client.openUrl(
          'GET', Uri.parse('http://127.0.0.1:8757/ligament'));
      getEvil.headers.set('origin', 'https://evil.example.com');
      final getEvilRes = await getEvil.close();
      expect(getEvilRes.statusCode, 403);
      expect(await getEvilRes.transform(utf8.decoder).join(), isEmpty);

      // OPTIONS — без ACPN (удалён вместе с CORS для публичных страниц)
      final opt = await (await client.openUrl(
        'OPTIONS',
        Uri.parse('http://127.0.0.1:8757/ligament'),
      ))
          .close();
      expect(opt.statusCode, 204);
      expect(opt.headers.value('Access-Control-Allow-Private-Network'), isNull);

      // прочее → 404
      final nf =
          await (await client.getUrl(Uri.parse('http://127.0.0.1:8757/other')))
              .close();
      expect(nf.statusCode, 404);
    });

    test(
        'A-2: /autoshare без wake-токена → 403; с токеном → 200; с Origin → 403',
        () async {
      if (await foreignPortBusy()) {
        markTestSkipped(
            'порт 8757 занят внешним процессом (запущено приложение?)');
        return;
      }
      SharedPreferences.setMockInitialValues(
          {'server_url': 'https://2fa.corp.local'});
      var delivered = '';
      final svc = LocalDetectService();
      svc.onAutoshare = (sid) => delivered = sid;
      addTearDown(svc.stop);
      await svc.start('uuid-a');
      expect(svc.isRunning, isTrue);

      // Токен публикуется в пер-пользовательский temp и читается вызывающим.
      final token = await LocalDetectService.readWakeToken();
      expect(token, isNotNull);
      expect(token, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(token, svc.wakeTokenForTest);

      Future<int> post({String? wakeToken, String? origin}) async {
        final client = HttpClient();
        try {
          final req =
              await client.post('127.0.0.1', kLocalDetectPort, '/autoshare');
          req.headers.contentType = ContentType.json;
          if (origin != null) req.headers.set('origin', origin);
          req.write(jsonEncode({
            'session_id': 'sid-1',
            if (wakeToken != null) 'wake_token': wakeToken,
          }));
          return (await req.close()).statusCode;
        } finally {
          client.close(force: true);
        }
      }

      // Без токена — 403 (даже с корректным payload)
      expect(await post(), 403);
      // С чужим токеном — 403
      expect(await post(wakeToken: '0' * 64), 403);
      // Токен в JSON-поле — 200
      expect(await post(wakeToken: token), 200);
      expect(delivered, 'sid-1');

      // Токен в заголовке X-Wake-Token — 200
      delivered = '';
      final client = HttpClient();
      try {
        final req =
            await client.post('127.0.0.1', kLocalDetectPort, '/autoshare');
        req.headers.contentType = ContentType.json;
        req.headers.set('X-Wake-Token', token!);
        req.write(jsonEncode({'session_id': 'sid-2'}));
        expect((await req.close()).statusCode, 200);
      } finally {
        client.close(force: true);
      }
      expect(delivered, 'sid-2');

      // Браузерный Origin (даже origin сервера) — 403: веб-кабинет не будит
      // трансляцию из браузера.
      expect(
          await post(wakeToken: token, origin: 'https://2fa.corp.local'), 403);
      expect(await post(wakeToken: token, origin: 'https://evil.example.com'),
          403);
      // localhost-Origin допустим (локальные инструменты)
      expect(
          await post(wakeToken: token, origin: 'http://localhost:5173'), 200);
    });

    test('A-2: рестарт слушателя ротирует wake-токен; stop() убирает файл',
        () async {
      if (await foreignPortBusy()) {
        markTestSkipped(
            'порт 8757 занят внешним процессом (запущено приложение?)');
        return;
      }
      SharedPreferences.setMockInitialValues({});
      final svc = LocalDetectService();
      addTearDown(svc.stop);
      await svc.start('uuid-a');
      final t1 = await LocalDetectService.readWakeToken();
      expect(t1, isNotNull);

      // Повторный start с тем же id — no-op, токен не меняется.
      await svc.start('uuid-a');
      expect(await LocalDetectService.readWakeToken(), t1);

      // Смена device_id — перезапуск с новым токеном.
      await svc.start('uuid-b');
      final t2 = await LocalDetectService.readWakeToken();
      expect(t2, isNotNull);
      expect(t2, isNot(t1));

      // Старый токен больше не действует.
      final client = HttpClient();
      try {
        final req =
            await client.post('127.0.0.1', kLocalDetectPort, '/autoshare');
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode({'session_id': 'sid', 'wake_token': t1}));
        expect((await req.close()).statusCode, 403);
      } finally {
        client.close(force: true);
      }

      // stop удаляет файл токена.
      await svc.stop();
      expect(await LocalDetectService.readWakeToken(), isNull);
    });

    test(
        'занятый порт — тихая деградация (warn без throw); рестарт, смена device_id и stop',
        () async {
      if (await foreignPortBusy()) {
        markTestSkipped(
            'порт 8757 занят внешним процессом (запущено приложение?)');
        return;
      }
      SharedPreferences.setMockInitialValues({});
      // Занимаем контрактный порт посторонним сервером.
      final blocker =
          await HttpServer.bind(InternetAddress.loopbackIPv4, kLocalDetectPort);
      addTearDown(() => blocker.close());

      final svc = LocalDetectService();
      addTearDown(svc.stop);

      // Порт занят: start обязан деградировать в warn, приложение живёт.
      await svc.start('uuid-a');
      expect(svc.isRunning, isFalse);

      // После освобождения порта слушатель поднимается.
      await blocker.close();
      await svc.start('uuid-a');
      expect(svc.isRunning, isTrue);

      // Свежий HttpClient на каждый запрос: пул keep-alive соединений
      // переживает рестарт слушателя и ломает запрос по мёртвому сокету.
      Future<Map<String, dynamic>> probe() async {
        final client = HttpClient();
        try {
          final res = await (await client
                  .getUrl(Uri.parse('http://127.0.0.1:8757/ligament')))
              .close();
          expect(res.statusCode, 200);
          return jsonDecode(await res.transform(utf8.decoder).join())
              as Map<String, dynamic>;
        } finally {
          client.close(force: true);
        }
      }

      expect((await probe())['device_id'], 'uuid-a');

      // Повторный start с тем же id — no-op; со сменой — перезапуск.
      await svc.start('uuid-a');
      expect((await probe())['device_id'], 'uuid-a');
      await svc.start('uuid-b');
      expect((await probe())['device_id'], 'uuid-b');

      // stop освобождает порт.
      await svc.stop();
      expect(svc.isRunning, isFalse);
      await expectLater(
        () async => await (await HttpClient()
                .getUrl(Uri.parse('http://127.0.0.1:8757/ligament')))
            .close(),
        throwsA(anyOf(isA<SocketException>(), isA<HttpException>())),
      );
    });
  });
}
