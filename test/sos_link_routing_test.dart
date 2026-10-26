import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ligament_authenticator/api/client.dart';
import 'package:ligament_authenticator/services/auth_state.dart';

void main() {
  const me = 'user-1';
  Map<String, dynamic> host(String id, String hostname,
          {String owner = me, String status = 'enrolled'}) =>
      {'id': id, 'hostname': hostname, 'owner_user_id': owner, 'status': status};

  group('sosLocalAgentId', () {
    test('matches own enrolled host by computer name, ignoring domain and case',
        () {
      final hosts = [
        host('a-laptop', 'LAPTOP-7'),
        host('a-desk', 'DESKTOP-ABC.corp.local'),
      ];
      expect(
          sosLocalAgentId(hosts, userId: me, hostname: 'desktop-abc'), 'a-desk');
    });

    test('never targets a PC owned by someone else or not enrolled', () {
      final hosts = [
        host('foreign', 'DESKTOP-ABC', owner: 'user-2'),
        host('archived', 'DESKTOP-ABC', status: 'archived'),
      ];
      expect(sosLocalAgentId(hosts, userId: me, hostname: 'DESKTOP-ABC'),
          isNull);
    });

    test('does not guess another own PC when the name does not match', () {
      expect(
          sosLocalAgentId([host('a-laptop', 'LAPTOP-7')],
              userId: me, hostname: 'DESKTOP-ABC'),
          isNull);
    });

    test('ambiguous duplicates fall back to the legacy path', () {
      final hosts = [host('a', 'DESKTOP-ABC'), host('b', 'desktop-abc')];
      expect(sosLocalAgentId(hosts, userId: me, hostname: 'DESKTOP-ABC'),
          isNull);
    });
  });

  test('sosQueueItem maps SOS request fields onto the queue card', () {
    final item = sosQueueItem({
      'id': 'req-1',
      'category': 'it',
      'requester_username': 'ivanov',
      'requester_display_name': '',
      'target_hostname': 'DESKTOP-ABC',
    });
    expect(item['sos_v2'], isTrue);
    expect(item['id'], 'req-1');
    expect(item.containsKey('display_name'), isFalse);
    expect(item['username'], 'ivanov');
    expect(item['pc_name'], 'DESKTOP-ABC');
    expect(item['access_mode'], 'full_control');
  });

  group('SOS HTTP errors', () {
    Future<(HttpServer, ApiClient)> startServer(
        Future<void> Function(HttpRequest) handler) async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        await utf8.decoder.bind(request).join();
        await handler(request);
      });
      addTearDown(() => server.close(force: true));
      return (
        server,
        ApiClient(baseUrl: 'http://127.0.0.1:${server.port}', token: 'tok')
      );
    }

    Future<void> jsonResponse(
        HttpRequest request, int status, Object body) async {
      request.response.statusCode = status;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(body));
      await request.response.close();
    }

    test('requestSupport fallback только для отсутствующего v2 endpoint',
        () async {
      var legacyCalls = 0;
      late HttpRequest lastRequest;
      final (_, client) = await startServer((request) async {
        lastRequest = request;
        if (request.uri.path == '/api/v1/app/link/sos/request') {
          await jsonResponse(request, 403, {'error': 'forbidden'});
        } else {
          legacyCalls++;
          await jsonResponse(request, 200, {'id': 'legacy'});
        }
      });

      await expectLater(
        client.requestSupport(
            category: 'it', problemSummary: 'help', targetAgentId: 'agent'),
        throwsA(isA<ApiException>()
            .having((e) => e.statusCode, 'status', 403)
            .having((e) => e.code, 'code', 'forbidden')),
      );
      expect(legacyCalls, 0);
      expect(lastRequest.uri.path, '/api/v1/app/link/sos/request');
    });

    test('404 v2 использует legacy, а non-200 очереди не маскируются', () async {
      var legacyCalls = 0;
      final (_, client) = await startServer((request) async {
        if (request.uri.path == '/api/v1/app/link/sos/request') {
          await jsonResponse(request, 404, {'error': 'not_found'});
        } else if (request.uri.path == '/api/v1/app/link/sos/requests') {
          await jsonResponse(request, 404, {'error': 'not_found'});
        } else {
          legacyCalls++;
          if (request.uri.path == '/api/v1/app/support/request') {
            await jsonResponse(request, 200, {'id': 'legacy'});
          } else {
            await jsonResponse(request, 200, [
              {'id': 'legacy-1'}
            ]);
          }
        }
      });

      final created = await client.requestSupport(
          category: 'it', problemSummary: 'help', targetAgentId: 'agent');
      expect(created['id'], 'legacy');
      expect(legacyCalls, 1);
      final queue = await client.getSupportQueue();
      expect(queue.single['id'], 'legacy-1');
    });

    test('getPendingSOSRequests/getSupportQueue сохраняют ApiException',
        () async {
      final (_, client) = await startServer((request) async {
        await jsonResponse(request, 500, {'error': 'db_error'});
      });
      await expectLater(
        client.getPendingSOSRequests(),
        throwsA(isA<ApiException>()
            .having((e) => e.statusCode, 'status', 500)
            .having((e) => e.code, 'code', 'db_error')),
      );
      await expectLater(
        client.getSupportQueue(),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', 'db_error')),
      );
    });
  });
}
