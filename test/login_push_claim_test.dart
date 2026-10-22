import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ligament_authenticator/api/client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  test('login throws ApiException with details on second_factor_required', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      if (req.uri.path == '/api/v1/app/login') {
        req.response.statusCode = HttpStatus.unauthorized;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({
          'error': 'second_factor_required',
          'challenge_id': 'ch-uuid-123',
          'claim_token': 'claim-tok-abc',
          'push_sent': true,
          'channel': 'app_push',
        }));
        await req.response.close();
      }
    });

    final client = ApiClient(baseUrl: 'http://${server.address.host}:${server.port}');
    try {
      await client.login(
        username: 'alice',
        password: 'password',
        deviceName: 'MacBook',
        platform: 'macos',
      );
      fail('Expected ApiException');
    } on ApiException catch (e) {
      expect(e.statusCode, equals(401));
      expect(e.code, equals('second_factor_required'));
      expect(e.details, isNotNull);
      expect(e.details!['challenge_id'], equals('ch-uuid-123'));
      expect(e.details!['claim_token'], equals('claim-tok-abc'));
      expect(e.details!['push_sent'], isTrue);
    } finally {
      await server.close(force: true);
    }
  });

  test('loginClaim handles pending, approved, and denied', () async {
    int requestCount = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      if (req.uri.path == '/api/v1/app/login/claim') {
        requestCount++;
        req.response.headers.contentType = ContentType.json;
        if (requestCount == 1) {
          req.response.statusCode = HttpStatus.ok;
          req.response.write(jsonEncode({'status': 'pending'}));
        } else if (requestCount == 2) {
          req.response.statusCode = HttpStatus.ok;
          req.response.write(jsonEncode({
            'token': 'bearer-token-123',
            'device_id': 'dev-id-456',
            'user': {'username': 'alice'},
          }));
        } else {
          req.response.statusCode = HttpStatus.ok;
          req.response.write(jsonEncode({
            'status': 'denied',
            'error': 'challenge_denied',
          }));
        }
        await req.response.close();
      }
    });

    final client = ApiClient(baseUrl: 'http://${server.address.host}:${server.port}');
    try {
      // 1. Pending
      final resp1 = await client.loginClaim(
        challengeId: 'ch-uuid-123',
        claimToken: 'claim-tok-abc',
        deviceName: 'MacBook',
        platform: 'macos',
      );
      expect(resp1['status'], equals('pending'));
      expect(resp1['token'], isNull);

      // 2. Approved
      final resp2 = await client.loginClaim(
        challengeId: 'ch-uuid-123',
        claimToken: 'claim-tok-abc',
        deviceName: 'MacBook',
        platform: 'macos',
      );
      expect(resp2['token'], equals('bearer-token-123'));
      expect(client.token, equals('bearer-token-123'));

      // 3. Denied
      final resp3 = await client.loginClaim(
        challengeId: 'ch-uuid-123',
        claimToken: 'claim-tok-abc',
        deviceName: 'MacBook',
        platform: 'macos',
      );
      expect(resp3['status'], equals('denied'));
    } finally {
      await server.close(force: true);
    }
  });
}
