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
}
