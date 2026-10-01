import 'package:flutter_test/flutter_test.dart';
import 'package:ligament_authenticator/services/sso/sso_ticket.dart';
import 'package:ligament_authenticator/services/sso/sso_ticket_flow.dart';
import 'package:ligament_authenticator/services/auth_state.dart'
    show normalizeBrowserSsoPrompt;

void main() {
  group('buildSsoTicketPath', () {
    test('строит путь по SID-заглушке', () {
      expect(
        buildSsoTicketPath(r'C:\ProgramData', 'S-1-5-21-1000-2000-3000-500'),
        r'C:\ProgramData\Ligament\sso\S-1-5-21-1000-2000-3000-500\sso.bin',
      );
    });

    test('терминальный бэкслеш корня не удваивается', () {
      expect(
        buildSsoTicketPath(r'C:\ProgramData\', 'S-1-5-21-1'),
        r'C:\ProgramData\Ligament\sso\S-1-5-21-1\sso.bin',
      );
    });
  });

  group('machineMatches', () {
    test('точное совпадение без учёта регистра', () {
      expect(machineMatches('WS-001', 'ws-001'), isTrue);
    });

    test('DNS-суффикс не ломает матч', () {
      expect(machineMatches('ws-001', 'WS-001.corp.local'), isTrue);
      expect(machineMatches('ws-001.corp.local', 'ws-001'), isTrue);
    });

    test('разные машины не матчатся', () {
      expect(machineMatches('ws-001', 'ws-002'), isFalse);
      // 'ws-001' vs 'ws-0011': короткие имена различны — не матч
      expect(machineMatches('ws-001', 'ws-0011.corp.local'), isFalse);
    });

    test('пустые значения безопасно дают false', () {
      expect(machineMatches(null, 'ws-001'), isFalse);
      expect(machineMatches('ws-001', null), isFalse);
      expect(machineMatches('', ''), isFalse);
    });
  });

  group('isExpired', () {
    test('истёкший и будущий expires_at', () {
      final now = DateTime(2026, 10, 1, 12, 0);
      expect(isExpired('2026-10-01T11:55:00Z', now: now.add(const Duration(hours: 6))), isTrue);
      expect(isExpired('2026-10-01T12:04:00Z', now: now), isFalse);
      expect(isExpired(null), isTrue); // нет срока = не показываем
    });

    test('epoch-секунды принимаются', () {
      // 1 секунда от эпохи против «сейчас» = минута от эпохи: истёк
      expect(
        isExpired(1, now: DateTime.fromMillisecondsSinceEpoch(60000)),
        isTrue,
      );
    });
  });

  group('SsoTicketFlow', () {
    test('200 — ok и запоминает expires_at', () async {
      final until = DateTime.now().add(const Duration(minutes: 5));
      var calls = 0;
      final flow = SsoTicketFlow(submit: (ticket) async {
        calls++;
        return SsoSubmitResponse(200, expiresAt: until);
      });
      final out = await flow.present('ticket-1');
      expect(out, SsoSubmitOutcome.ok);
      expect(flow.verifiedUntil, until);
      expect(calls, 1);
    });

    test('404 not_enabled — sticky: повтор не уходит', () async {
      var calls = 0;
      final flow = SsoTicketFlow(submit: (t) async {
        calls++;
        return const SsoSubmitResponse(404);
      });
      expect(await flow.present('t'), SsoSubmitOutcome.notEnabled);
      expect(await flow.present('t'), isNull); // проглочено sticky-флагом
      expect(calls, 1);
      expect(flow.isServerNotEnabled, isTrue);
    });

    test('429 — cooldown: вторая попытка в течение минуты не уходит', () async {
      var calls = 0;
      final flow = SsoTicketFlow(submit: (t) async {
        calls++;
        return const SsoSubmitResponse(429);
      });
      expect(await flow.present('t'), SsoSubmitOutcome.rateLimited);
      expect(await flow.present('t'), isNull);
      expect(calls, 1);
    });

    test('401 и 409 — invalid, тихо', () async {
      for (final code in [401, 409]) {
        final flow = SsoTicketFlow(submit: (t) async => SsoSubmitResponse(code));
        expect(await flow.present('t'), SsoSubmitOutcome.invalid);
        expect(flow.verifiedUntil, isNull);
      }
    });

    test('транспортный сбой — network, без throw', () async {
      final flow = SsoTicketFlow(submit: (t) async => throw Exception('boom'));
      expect(await flow.present('t'), SsoSubmitOutcome.network);
    });

    test('нет билета — попытки нет вовсе', () async {
      var calls = 0;
      final flow = SsoTicketFlow(submit: (t) async {
        calls++;
        return const SsoSubmitResponse(200);
      });
      expect(await flow.present(null), isNull);
      expect(await flow.present(''), isNull);
      expect(calls, 0);
    });
  });

  group('normalizeBrowserSsoPrompt', () {
    test('плоский и вложенный форматы', () {
      final flat = normalizeBrowserSsoPrompt({
        'id': 'ch-1',
        'sp_name': 'Confluence',
        'username': 'ivanov',
        'machine': 'ws-001',
        'auto_allowed': true,
        'expires_at': '2099-01-01T00:00:00Z',
      });
      expect(flat['id'], 'ch-1');
      expect(flat['sp_name'], 'Confluence');
      expect(flat['auto_allowed'], isTrue);

      final nested = normalizeBrowserSsoPrompt({
        'type': 'browser_sso',
        'challenge': {'id': 'ch-2', 'sp': 'Jira', 'host': 'ws-002'},
      });
      expect(nested['id'], 'ch-2');
      expect(nested['sp_name'], 'Jira');
      expect(nested['machine'], 'ws-002');
      expect(nested['auto_allowed'], isFalse);
    });
  });
}
