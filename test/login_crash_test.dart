import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ligament_authenticator/api/client.dart';
import 'package:ligament_authenticator/services/auth_state.dart';
import 'package:ligament_authenticator/services/telemetry_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Репро краша входа v0.8.133: «Ошибка входа: Null check operator used on a
/// null value» (диалог LoginScreen ← AuthState.login). Три сценария, при
/// каждом login НЕ бросает / бросает понятную ошибку вместо null-краша:
///
///  (а) нулевые FFI-указатели телеметрии (kernel32 не загрузился) —
///      дефолтные метрики, вход жив;
///  (б) ответ сервера без security_posture (и без token/user — понятная
///      ошибка, не TypeError/null-check);
///  (в) исключение в collectPosture — вход продолжается с пустым posture.
///
/// Механика как в desktop_confirm_test.dart: настоящий HttpServer на
/// loopback (HttpClient мокается НЕ через HttpOverrides — геттер из SDK
/// изъят), ApiClient ходит по реальному сокету; каналы audioplayers и
/// flutter_secure_storage замоканы (конструктор AuthState / запись токена).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
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
    // FlutterSecureStorage: login() пишет токен — на MethodChannel без
    // нативной части это MissingPluginException, что роняло бы вход.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => null,
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('xyz.luan/audioplayers'), null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('xyz.luan/audioplayers.global'), null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'), null);
  });

  // Мок 2fa-сервера на реальном сокете. loginBodies фиксирует тело
  // POST /api/v1/app/login (для проверки fallback-постуры).
  Future<(HttpServer, Map<String, Map<String, dynamic>>)> startMock({
    Map<String, dynamic>? loginResponse,
    int loginStatus = 200,
  }) async {
    final loginBodies = <String, Map<String, dynamic>>{};
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final rawBody = await utf8.decoder.bind(req).join();
      if (req.method == 'POST' && req.uri.path == '/api/v1/app/login') {
        loginBodies['last'] =
            rawBody.isEmpty ? <String, dynamic>{} : jsonDecode(rawBody) as Map<String, dynamic>;
        req.response.statusCode = loginStatus;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(loginResponse ?? {}));
        await req.response.close();
        return;
      }
      // refreshAll(): пустые ответы на всё — важен сам факт «не бросило».
      const emptyLists = <String, String>{
        'GET /api/v1/app/challenges/pending': '[]',
        'GET /api/v1/app/me/apps': '[]',
        'GET /api/v1/app/me/history': '[]',
        'GET /api/v1/app/me/notifications?limit=50': '{"notifications":[]}',
      };
      final key = '${req.method} ${req.uri.path}${req.uri.query.isEmpty ? '' : '?${req.uri.query}'}';
      if (emptyLists.containsKey(key)) {
        req.response.statusCode = 200;
        req.response.headers.contentType = ContentType.json;
        req.response.write(emptyLists[key]);
        await req.response.close();
        return;
      }
      if (req.method == 'POST' && req.uri.path == '/api/v1/app/telemetry') {
        req.response.statusCode = 200;
        req.response.headers.contentType = ContentType.json;
        req.response.write('{"is_compliant": true}');
        await req.response.close();
        return;
      }
      if (req.method == 'GET' && req.uri.path == '/api/v1/app/support/current') {
        req.response.statusCode = 200;
        req.response.headers.contentType = ContentType.json;
        req.response.write('{"active": false}');
        await req.response.close();
        return;
      }
      if (req.method == 'GET' && req.uri.path == '/api/v1/app/config') {
        req.response.statusCode = 200;
        req.response.headers.contentType = ContentType.json;
        req.response.write('{}');
        await req.response.close();
        return;
      }
      if (req.method == 'GET' && req.uri.path == '/api/v1/app/rdp/targets') {
        req.response.statusCode = 200;
        req.response.headers.contentType = ContentType.json;
        req.response.write('{"targets": []}');
        await req.response.close();
        return;
      }
      req.response.statusCode = 404;
      req.response.headers.contentType = ContentType.json;
      req.response.write('{"error":"unmocked $key"}');
      await req.response.close();
    });
    return (server, loginBodies);
  }

  AuthState makeAuth(HttpServer server) {
    final auth = AuthState();
    auth.serverUrl = 'http://127.0.0.1:${server.port}';
    auth.api = ApiClient(baseUrl: auth.serverUrl!);
    addTearDown(() async {
      auth.telemetry.stopReporting();
      auth.ws.disconnect();
      await auth.localDetect.stop();
    });
    return auth;
  }

  Map<String, dynamic> okLoginResponse({bool withPosture = false}) => {
        'token': 'tok-1',
        'user': {'username': 'ivanov', 'display_name': 'Иван'},
        'device_id': '11111111-2222-3333-4444-555555555555',
        if (withPosture)
          'security_posture': {
            'platform': 'windows',
            'is_compliant': true,
          },
      };

  group('(а) нулевые FFI-указатели телеметрии', () {
    test('windowsDiskMetrics(null) — дефолтные метрики, без броска', () {
      final m = TelemetryService.windowsDiskMetrics(null);
      expect(m['disk_percent'], 0);
      expect(m['disk_free_gb'], 0);
      expect(m['disk_total_gb'], 0);
      expect(m['disk_warning'], false);
    });

    test('windowsCpuUsage(null, ...) — (null, null), без броска', () {
      final (usage, counters) =
          TelemetryService.windowsCpuUsage(null, null);
      expect(usage, isNull);
      expect(counters, isNull);
      // Существующая база не затирается: метрики остаются дефолтными.
      const prev = WinCpuCounters(10, 20, 30);
      final (usage2, counters2) =
          TelemetryService.windowsCpuUsage(null, prev);
      expect(usage2, isNull);
      expect(counters2, isNull);
    });

    test('collectDiskMetrics/collectCpuMetrics на хосте без Windows FFI не бросают', () async {
      final t = TelemetryService();
      final disk = await t.collectDiskMetrics();
      expect(disk.containsKey('disk_percent'), isTrue);
      final cpu = await t.collectCpuMetrics();
      expect(cpu.containsKey('cpu_percent') || cpu.containsKey('cpu_warning'), isTrue);
    });

    test('полный login: телеметрия с null-FFI (любой не-Windows хост) не роняет вход', () async {
      final (server, _) = await startMock(loginResponse: okLoginResponse());
      addTearDown(() => server.close());

      final auth = makeAuth(server);
      await auth.login('ivanov', 'secret');
      expect(auth.isLoggedIn, isTrue);
      expect(auth.token, 'tok-1');
    });
  });

  group('(б) ответ сервера без security_posture / без обязательных полей', () {
    test('login без security_posture: вход жив (null-каста больше нет)', () async {
      final (server, _) = await startMock(loginResponse: okLoginResponse());
      addTearDown(() => server.close());

      final auth = makeAuth(server);
      // Прежде `resp['security_posture'] as Map<String, dynamic>?` при
      // отсутствии/не-Map значении рисковал TypeError; теперь вход жив.
      // (currentPosture после login перезаписывается refreshAll ->
      // checkPosture локальным сбором, поэтому проверяем сам факт входа.)
      await auth.login('ivanov', 'secret');
      expect(auth.isLoggedIn, isTrue);
      expect(auth.token, 'tok-1');
    });

    test('login с security_posture: вход жив, комплаенс подхватывается', () async {
      final (server, _) =
          await startMock(loginResponse: okLoginResponse(withPosture: true));
      addTearDown(() => server.close());

      final auth = makeAuth(server);
      await auth.login('ivanov', 'secret');
      expect(auth.isLoggedIn, isTrue);
      expect(auth.isCompliant, isTrue); // из posture сервера/локального сбора
    });

    test('ответ без token/user — понятная ошибка, НЕ Null check operator', () async {
      final (server, _) = await startMock(loginResponse: {'user': null});
      addTearDown(() => server.close());

      final auth = makeAuth(server);
      await expectLater(
        auth.login('ivanov', 'secret'),
        throwsA(isA<Exception>().having(
            (e) => e.toString(), 'text', isNot(contains('Null check operator')))),
      );
      expect(auth.isLoggedIn, isFalse);
    });

    test('api == null — понятная ошибка вместо null-краша (logout между экранами)', () async {
      final auth = AuthState();
      auth.serverUrl = 'https://server.example.com';
      // api не создавался (после logout) — прежде здесь ронял `api!`.
      await expectLater(
        auth.login('ivanov', 'secret'),
        throwsA(isA<Exception>().having(
            (e) => e.toString(), 'text', isNot(contains('Null check operator')))),
      );
    });
  });

  group('(в) исключение в collectPosture', () {
    test('бросающая телеметрия: login не бросает, уходит пустой posture', () async {
      final (server, bodies) = await startMock(loginResponse: okLoginResponse());
      addTearDown(() => server.close());

      final auth = makeAuth(server);
      auth.telemetry = _CrashingTelemetry();

      await auth.login('ivanov', 'secret'); // НЕ бросает
      expect(auth.isLoggedIn, isTrue);
      // На сервер ушёл fallback — пустой security_posture.
      expect(bodies['last']?['security_posture'], isEmpty);
    });
  });
}

/// Телеметрия, у которой ломается ВСЁ (эмуляция сорванного kernel32/FFI
/// и любых дочерних процессов сбора).
class _CrashingTelemetry extends TelemetryService {
  @override
  Future<Map<String, dynamic>> collectPosture({bool forceRefresh = false}) async {
    throw StateError('collectPosture: kernel32 unavailable (test)');
  }
}
