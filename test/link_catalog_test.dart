import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ligament_authenticator/api/client.dart';
import 'package:ligament_authenticator/screens/link_catalog_screen.dart';

void main() {
  group('searchLinkHosts', () {
    final hosts = <Map<String, dynamic>>[
      {
        'hostname': 'BUH-001',
        'ad_ou': 'OU=Accounting,DC=corp',
        'group_name': 'Accounting',
        'os_family': 'windows',
        'os_version': '11 Pro',
        'tags': ['1c', 'finance'],
      },
      {
        'hostname': 'SRV-PG-01',
        'ad_ou': 'OU=Servers,DC=corp',
        'group_name': 'Servers',
        'os_family': 'linux',
        'tags': ['database'],
      },
    ];

    test('matches every token across different fields, regardless of order',
        () {
      expect(searchLinkHosts(hosts, 'accounting BUH-001'), [hosts.first]);
      expect(searchLinkHosts(hosts, 'FINANCE 11'), [hosts.first]);
    });

    test('returns all for blank query and none for missing token', () {
      expect(searchLinkHosts(hosts, '  '), hosts);
      expect(searchLinkHosts(hosts, 'accounting missing'), isEmpty);
    });

    test('trigram narrowing preserves arbitrary substring matching', () {
      final inventory = <Map<String, dynamic>>[
        {
          'hostname': 'XHOSTY-001',
          'tags': ['finance-team']
        },
        {
          'hostname': 'OTHER-001',
          'tags': ['finance-team']
        },
      ];
      final index = LinkHostSearchIndex(inventory);

      expect(index.search('ost finance'), [inventory.first]);
      expect(index.search('hosty-00'), [inventory.first]);
      expect(index.search('st finance'), [inventory.first]);
    });

    test('indexes user, IP and department for multi-token lookup', () {
      final inventory = <Map<String, dynamic>>[
        {
          'hostname': 'BUH-001',
          'username': 'maria.ivanova',
          'ip': '192.168.10.15',
          'owner_username': 'owner.maria',
          'public_ip': '203.0.113.20',
          'local_ips': ['10.1.2.3'],
          'department': 'Finance',
        },
      ];
      final index = LinkHostSearchIndex(inventory);

      expect(index.search('MARIA 192.168'), [inventory.single]);
      expect(index.search('owner.maria 10.1.2'), [inventory.single]);
      expect(index.search('finance buh'), [inventory.single]);
      expect(identical(index.search('  '), inventory), isTrue);
    });
  });

  test('10k-host indexed search benchmark', () {
    final hosts = List<Map<String, dynamic>>.generate(
      10000,
      (index) => <String, dynamic>{
        'id': index,
        'hostname': 'HOST-${index.toString().padLeft(5, '0')}',
        'os_family': 'windows',
        'department': 'department-${index % 20}',
        'tags': <String>['managed', 'finance'],
      },
      growable: false,
    );
    final index = LinkHostSearchIndex(hosts);
    final samples = <int>[];
    List<Map<String, dynamic>> matches = const [];

    for (var iteration = 0; iteration < 25; iteration++) {
      final stopwatch = Stopwatch()..start();
      matches = index.search('host-05000 windows department-0');
      stopwatch.stop();
      samples.add(stopwatch.elapsedMicroseconds);
    }
    samples.sort();

    expect(matches, hasLength(1));
    expect(matches.single['id'], 5000);
    // Diagnostic only: report real-host-size latency without a flaky timing gate.
    // ignore: avoid_print
    print(
      'Link 10k search: p50=${samples[12]}us p95=${samples[23]}us (25 samples)',
    );
  });

  test('ApiClient loads authenticated Link inventory', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final requestHandled = Completer<void>();
    server.listen((request) async {
      try {
        expect(request.uri.path, '/api/v1/app/link/hosts');
        expect(request.headers.value(HttpHeaders.authorizationHeader),
            'Bearer test-token');
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({
            'hosts': [
              {'id': 'agent-1', 'hostname': 'BUH-001', 'is_online': true},
            ],
          }));
        await request.response.close();
        requestHandled.complete();
      } catch (error, stackTrace) {
        requestHandled.completeError(error, stackTrace);
      }
    });

    try {
      final hosts = await ApiClient(
        baseUrl: 'http://${server.address.address}:${server.port}',
        token: 'test-token',
      ).getLinkHosts();
      await requestHandled.future;
      expect(hosts, hasLength(1));
      expect(hosts.single['hostname'], 'BUH-001');
      expect(hosts.single['is_online'], isTrue);
    } finally {
      await server.close(force: true);
    }
  });

  test('ApiClient requests one-time host binding credential', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final requestHandled = Completer<void>();
    server.listen((request) async {
      try {
        expect(request.method, 'POST');
        expect(request.uri.path, '/api/v1/app/link/agents/enrollment-token');
        expect(request.headers.value(HttpHeaders.authorizationHeader),
            'Bearer test-token');
        request.response
          ..statusCode = HttpStatus.created
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({
            'token': 'a1' * 32,
            'expires_at': '2026-10-20T12:00:00Z',
          }));
        await request.response.close();
        requestHandled.complete();
      } catch (error, stackTrace) {
        requestHandled.completeError(error, stackTrace);
      }
    });

    try {
      final credential = await ApiClient(
        baseUrl: 'http://${server.address.address}:${server.port}',
        token: 'test-token',
      ).createLinkEnrollmentCredential();
      await requestHandled.future;
      expect(credential.token, 'a1' * 32);
      expect(credential.expiresAt.isUtc, isTrue);
    } finally {
      await server.close(force: true);
    }
  });

  test('ApiClient starts session and polls agent signaling with cursor',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final requestsHandled = Completer<void>();
    var handledCount = 0;
    server.listen((request) async {
      try {
        expect(request.headers.value(HttpHeaders.authorizationHeader),
            'Bearer test-token');
        if (request.uri.path == '/api/v1/app/link/sessions/request') {
          final body = jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>;
          expect(body['agent_id'], 'agent-1');
          expect(body['access_mode'], 'view');
          request.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({
              'session_id': 'session-1',
              'status': 'connecting',
              'relay_url': '/api/v1/link/relay/ws',
              'relay_token': 'a' * 64,
            }));
        } else {
          expect(
              request.uri.path, '/api/v1/app/link/sessions/session-1/signal');
          expect(request.uri.queryParameters['after'], '17');
          request.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({
              'signals': [
                {
                  'id': 18,
                  'type': 'session_answer',
                  'payload': {'accepted': true}
                },
              ],
              'next_cursor': 18,
            }));
        }
        await request.response.close();
        handledCount++;
        if (handledCount == 2) requestsHandled.complete();
      } catch (error, stackTrace) {
        if (!requestsHandled.isCompleted) {
          requestsHandled.completeError(error, stackTrace);
        }
      }
    });

    try {
      final api = ApiClient(
        baseUrl: 'http://${server.address.address}:${server.port}',
        token: 'test-token',
      );
      final session = await api.requestLinkSession(agentId: 'agent-1');
      expect(session['session_id'], 'session-1');
      final signals = await api.getLinkSessionSignals(
        sessionId: 'session-1',
        after: 17,
      );
      expect(signals['next_cursor'], 18);
      expect(signals['signals'], hasLength(1));
      await requestsHandled.future;
    } finally {
      await server.close(force: true);
    }
  });
}
