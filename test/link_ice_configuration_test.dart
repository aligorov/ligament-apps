import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ligament_authenticator/api/client.dart';

void main() {
  Future<ApiClient> clientFor(int status, String body) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      expect(request.uri.path, '/api/v1/app/ice-servers');
      expect(request.headers.value(HttpHeaders.authorizationHeader),
          'Bearer test-token');
      request.response.statusCode = status;
      request.response.write(body);
      await request.response.close();
    });
    return ApiClient(
        baseUrl: 'http://127.0.0.1:${server.port}', token: 'test-token');
  }

  test('Link retrieves current TURN credentials before negotiation', () async {
    final client = await clientFor(
        200,
        jsonEncode({
          'ice_servers': [
            {
              'urls': ['turns:relay.example.test:443?transport=tcp'],
              'username': 'user',
              'credential': 'credential'
            }
          ],
        }));
    final servers = await client.getLinkIceServers();
    expect(servers.single['credential'], 'credential');
    expect(
        servers.single['urls'], ['turns:relay.example.test:443?transport=tcp']);
  });

  test('Link does not hide authentication errors as empty TURN config',
      () async {
    final client = await clientFor(401, '{}');
    await expectLater(client.getLinkIceServers(), throwsA(isA<ApiException>()));
  });

  test('Link rejects malformed configuration rather than losing entries',
      () async {
    final client = await clientFor(200, '{"ice_servers":[42]}');
    await expectLater(client.getLinkIceServers(), throwsFormatException);
  });

  test('Explicit empty configuration permits direct local connections',
      () async {
    final client = await clientFor(200, '{"ice_servers":[]}');
    expect(await client.getLinkIceServers(), isEmpty);
  });
}
