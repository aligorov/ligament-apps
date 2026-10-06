import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ligament_authenticator/services/local_detect_service.dart';

/// Этап D «умный 2FA»: контракт локального детекта (127.0.0.1:8757) и
/// поведение живого слушателя. Тесты сокета — на реальном HttpClient
/// (HttpOverrides не используется и не нужен).
void main() {
  group('localDetectResponse — контракт (чистая функция)', () {
    test('GET /ligament → 200 с телом {"v":1,"device_id":...}', () {
      final r = localDetectResponse('GET', '/ligament', 'uuid-1234');
      expect(r.status, 200);
      final data = jsonDecode(r.body) as Map<String, dynamic>;
      expect(data['v'], 1);
      expect(data['device_id'], 'uuid-1234');
      expect(data.keys.toSet(), {'v', 'device_id'});
    });

    test('GET /ligament — заголовки ACAO:* и Cache-Control: no-store', () {
      final r = localDetectResponse('GET', '/ligament', 'x');
      expect(r.headers['Access-Control-Allow-Origin'], '*');
      expect(r.headers['Cache-Control'], 'no-store');
      expect(r.headers['Content-Type'], contains('application/json'));
    });

    test('OPTIONS /ligament → 204 c Access-Control-Allow-Private-Network: true (preflight Chrome LNA)', () {
      final r = localDetectResponse('OPTIONS', '/ligament', 'x');
      expect(r.status, 204);
      expect(r.body, isEmpty);
      expect(r.headers['Access-Control-Allow-Origin'], '*');
      expect(r.headers['Access-Control-Allow-Private-Network'], 'true');
      expect(r.headers['Access-Control-Allow-Methods']!, contains('GET'));
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

  group('LocalDetectService — живой сокет на 127.0.0.1:8757', () {
    test('полный контракт через реальный HttpClient (GET/OPTIONS/404)', () async {
      // flutter test исполняется на десктоп-хосте CI (ubuntu/macos/windows).
      expect(LocalDetectService.isSupported, isTrue);

      final svc = LocalDetectService();
      addTearDown(svc.stop);
      await svc.start('11111111-2222-3333-4444-555555555555');
      expect(svc.isRunning, isTrue);

      final client = HttpClient();
      addTearDown(client.close);

      // GET → 200 + CORS + no-store + точное тело контракта
      final get =
          await (await client.getUrl(Uri.parse('http://127.0.0.1:8757/ligament'))).close();
      expect(get.statusCode, 200);
      expect(get.headers.value('Access-Control-Allow-Origin'), '*');
      expect(get.headers.value(HttpHeaders.cacheControlHeader), 'no-store');
      final body =
          jsonDecode(await get.transform(utf8.decoder).join()) as Map<String, dynamic>;
      expect(body['v'], 1);
      expect(body['device_id'], '11111111-2222-3333-4444-555555555555');

      // OPTIONS (preflight Chrome Local Network Access)
      final opt = await (await client.openUrl(
        'OPTIONS',
        Uri.parse('http://127.0.0.1:8757/ligament'),
      ))
          .close();
      expect(opt.statusCode, 204);
      expect(opt.headers.value('Access-Control-Allow-Private-Network'), 'true');
      expect(opt.headers.value('Access-Control-Allow-Origin'), '*');

      // прочее → 404
      final nf =
          await (await client.getUrl(Uri.parse('http://127.0.0.1:8757/other'))).close();
      expect(nf.statusCode, 404);
    });

    test('занятый порт — тихая деградация (warn без throw); рестарт, смена device_id и stop', () async {
      // Занимаем контрактный порт посторонним сервером.
      final blocker = await HttpServer.bind(InternetAddress.loopbackIPv4, kLocalDetectPort);
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

      // Повторный start с тем же id — no-op; со сменённым — перезапуск.
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
