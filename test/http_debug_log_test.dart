import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ligament_authenticator/api/client.dart';
import 'package:ligament_authenticator/services/debug_log_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late HttpServer server;
  late DebugLogService logs;
  late ApiClient client;
  HttpOverrides? previousOverrides;

  setUp(() async {
    previousOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('http-debug-');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    logs =
        DebugLogService(nativeWindows: false, directory: () async => directory);
    await logs.setEnabled(true);
    client = ApiClient(
      baseUrl: 'http://${server.address.host}:${server.port}',
      token: 'private-bearer-token',
      debugLogs: logs,
    );
  });

  tearDown(() async {
    await server.close(force: true);
    await logs.flush();
    await directory.delete(recursive: true);
    HttpOverrides.global = previousOverrides;
  });

  Future<String> content() async {
    await logs.flush();
    return File(logs.path!).readAsString();
  }

  test('all HTTP verbs correlate route, status, bytes and duration', () async {
    final requests = <String>[];
    final bodies = <String>[];
    server.listen((request) async {
      requests.add(request.method);
      bodies.add(await utf8.decoder.bind(request).join());
      expect(request.headers.value(HttpHeaders.authorizationHeader),
          'Bearer private-bearer-token');
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'ok': true,
        'token': 'private-response-token',
        'username': 'private-profile-name',
      }));
      await request.response.close();
    });
    await client.getProfile();
    await client.login(
      username: 'private-login-name',
      password: 'private-password',
      code: '284917',
      deviceName: 'private-device-name',
      platform: 'macos',
    );
    client.token = 'private-bearer-token';
    await client.updateNotificationSettings(
      loginSuccess: true,
      loginDenied: false,
      notifyTG: true,
      notifyEmail: false,
    );
    await client.updateLinkHost('private-agent-secret',
        unattendedEnabled: true);
    expect(requests, ['GET', 'POST', 'PUT', 'PATCH']);
    expect(bodies[1], contains('private-password'));
    final text = await content();
    final lines = const LineSplitter().convert(text);
    for (var i = 0; i < requests.length; i++) {
      final id = i + 1;
      final request = lines.singleWhere((line) =>
          line.contains('event=http.request ') &&
          line.contains('request_id=$id '));
      final response = lines.singleWhere((line) =>
          line.contains('event=http.response ') &&
          line.contains('request_id=$id '));
      expect(request, contains('method=${requests[i]}'));
      expect(request, contains('server=127.0.0.1:${server.port}'));
      expect(request, contains('transport=http'));
      expect(request, contains('sent_bytes=${utf8.encode(bodies[i]).length}'));
      expect(response, contains('http_status=200'));
      expect(response, matches(RegExp(r'duration_ms=\d+')));
      expect(response, matches(RegExp(r'response_bytes=[1-9]\d*')));
      expect(response, contains('result=received'));
    }
    expect(text, contains('route=/api/v1/app/link/hosts/{id}'));
    for (final secret in [
      'private-bearer-token',
      'private-response-token',
      'private-profile-name',
      'private-login-name',
      'private-password',
      '284917',
      'private-device-name',
      'private-agent-secret',
    ]) {
      expect(text, isNot(contains(secret)));
    }
  });

  test('HTTP rejection logs code and status but no body or query', () async {
    server.listen((request) async {
      expect(request.uri.queryParameters['target'], 'private-group-target');
      request.response.statusCode = HttpStatus.forbidden;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'error': 'access_denied',
        'message': 'private-error-message',
        'token': 'private-response-token',
      }));
      await request.response.close();
    });
    await expectLater(
      client.getLinkGroupAccess(type: 'group', target: 'private-group-target'),
      throwsA(isA<ApiException>()),
    );
    final text = await content();
    expect(text, contains('route=/api/v1/app/link/group-access'));
    expect(text, contains('http_status=403'));
    expect(text, contains('reason=access_denied'));
    expect(text, contains('result=http_error'));
    expect(text, isNot(contains('event=http.failed')));
    for (final secret in [
      'private-group-target',
      'private-error-message',
      'private-response-token',
      '?type=',
      'Authorization'
    ]) {
      expect(text, isNot(contains(secret)));
    }
  });

  test('unknown server error code is redacted without changing API errors',
      () async {
    server.listen((request) async {
      request.response.statusCode = HttpStatus.forbidden;
      request.response.write('{"error":"private_error_secret"}');
      await request.response.close();
    });
    await expectLater(
        client.getLinkGroupAccess(type: 'group', target: 'safe'),
        throwsA(isA<ApiException>()
            .having((error) => error.code, 'code', 'private_error_secret')));
    final text = await content();
    expect(text, contains('reason=unknown'));
    expect(text, isNot(contains('private_error_secret')));
  });

  test('transport failure preserves request ID and failure duration', () async {
    await server.close(force: true);
    await expectLater(client.getConfig(), throwsA(isA<Exception>()));
    final text = await content();
    expect(text, contains('event=http.request request_id=1'));
    expect(text, contains('event=http.failed'));
    expect(text, contains('request_id=1 method=GET'));
    expect(text, contains('route=/api/v1/app/config'));
    expect(text, contains('result=transport_error'));
    expect(text, matches(RegExp(r'duration_ms=\d+')));
    expect(text, isNot(contains('event=http.response')));
    expect(text, isNot(contains('Connection refused')));
  });

  test('disabling logs preserves request behavior and stops traces', () async {
    server.listen((request) async {
      request.response.write('{}');
      await request.response.close();
    });
    await logs.setEnabled(false);
    final before = await content();
    expect(await client.getProfile(), isEmpty);
    expect(await content(), before);
  });

  test('route templates discard unknown path components and query strings', () {
    expect(
        ApiClient.debugRoute(
            'https://user:private-password@example.test/api/v1/app/link/hosts/'
            '10000000-0000-4000-8000-000000000001?token=private-token'),
        '/api/v1/app/link/hosts/{id}');
    expect(
        ApiClient.debugRoute(
            'https://example.test/private-tenant/api/v1/app/support/chat/private-user/messages'),
        '/{id}/api/v1/app/support/chat/{id}/messages');
    expect(
        ApiClient.debugRoute(
            'https://example.test/api/v1/app/link/hosts/%70rivate'),
        '/api/v1/app/link/hosts/{id}');
  });
}
