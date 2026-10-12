import 'package:flutter_test/flutter_test.dart';
import 'package:ligament_authenticator/services/support_service.dart';

/// A-1 (аудит 2026-10-12, регрессия v1.1.38): транспортный гейт ввода.
///
/// Команды управления (mouse_*/key_*/hotkey/text_input/block_input/
/// clipboard_*/file_*/reboot), пришедшие через сигнальный WS-канал,
/// НЕ исполняются; те же команды из DataChannel (DTLS) исполняются.
/// Исполнение мокается serviceInput-колбэком serviceHost-режима,
/// поэтому WebRTC-стек не нужен.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  SupportService makeService(
    List<Map<String, dynamic>> injected, {
    String accessMode = 'full_control',
  }) {
    final svc = SupportService(
      serviceHost: true,
      serviceInput: (m) async {
        injected.add(Map<String, dynamic>.from(m));
      },
    );
    svc.setAuthorizing(
      sessionId: 'sess-1',
      accessMode: accessMode,
      owner: false,
    );
    return svc;
  }

  group('A-1: команды управления через сигнальный канал отклоняются', () {
    test('прямые типы mouse_*/key_*/hotkey/text_input/block_input/…', () async {
      final injected = <Map<String, dynamic>>[];
      final svc = makeService(injected);

      const rejected = [
        {'type': 'mouse_move', 'x': 0.5, 'y': 0.5},
        {'type': 'mouse_down', 'button': 0},
        {'type': 'mouse_up', 'button': 0},
        {'type': 'mouse_click', 'button': 0},
        {'type': 'click', 'button': 0},
        {'type': 'wheel', 'deltaY': -3.0},
        {'type': 'mouse_wheel', 'deltaY': -3.0},
        {'type': 'key_down', 'key': 'A'},
        {'type': 'key_up', 'key': 'A'},
        {'type': 'hotkey', 'action': 'ctrl_alt_del'},
        {'type': 'text_input', 'text': 'hello'},
        {'type': 'block_input', 'blocked': true},
        {'type': 'clipboard_set', 'text': 'steal'},
        {'type': 'clipboard_get'},
        {'type': 'file_start', 'transfer_id': 't1', 'filename': 'a.exe'},
        {
          'type': 'file_chunk',
          'transfer_id': 't1',
          'chunk_index': 0,
          'data': 'AA=='
        },
        {'type': 'file_end', 'transfer_id': 't1'},
        {'type': 'reboot'},
      ];
      for (final cmd in rejected) {
        await svc.handleRemoteSignal(cmd);
      }
      expect(injected, isEmpty,
          reason: 'команды управления из сигналинга не должны исполняться');
    });

    test('обёртка input_control (регрессия v1.1.38) отклоняется', () async {
      final injected = <Map<String, dynamic>>[];
      final svc = makeService(injected);

      await svc.handleRemoteSignal({
        'type': 'input_control',
        'data': {'type': 'mouse_move', 'x': 0.25, 'y': 0.75},
      });
      await svc.handleRemoteSignal({
        'type': 'input_control',
        'data': {'type': 'key_down', 'key': 'Win'},
      });
      await svc.handleRemoteSignal({
        'type': 'input_control',
        'data': {'type': 'reboot'},
      });
      // Пустая обёртка без data — тоже не исполняется.
      await svc.handleRemoteSignal({'type': 'input_control'});
      expect(injected, isEmpty);
    });

    test('конверт signal.data с командой управления отклоняется', () async {
      final injected = <Map<String, dynamic>>[];
      final svc = makeService(injected);

      await svc.handleRemoteSignal({
        'data': {'type': 'mouse_move', 'x': 0.1, 'y': 0.9},
      });
      expect(injected, isEmpty);
    });
  });

  group('A-1: сигнально-разрешённые типы работают как раньше', () {
    test('chat_message доставляется', () async {
      final received = <String>[];
      // Обычный (не serviceHost) инстанс: чат — фича SOS-клиента,
      // SYSTEM-worker'у чат запрещён отдельным гейтом.
      final svc = SupportService();
      svc.onChatMessageReceived = (m) => received.add(m.text);

      await svc.handleRemoteSignal({
        'type': 'chat_message',
        'id': 'm1',
        'sender': 'operator',
        'sender_name': 'Инженер',
        'text': 'проверка чата',
        'timestamp': 1728700000000,
      });
      expect(received, ['проверка чата']);
      expect(svc.chatMessages, isNotEmpty);
    });

    test('input_control с информационным подтипом screen_list допустим',
        () async {
      final injected = <Map<String, dynamic>>[];
      final svc = makeService(injected);

      await svc.handleRemoteSignal({
        'type': 'input_control',
        'data': {'type': 'screen_list'},
      });
      // screen_list не является вводом: serviceInput не вызывается,
      // но и ошибки/исключения быть не должно.
      expect(injected, isEmpty);
      expect(svc.state, SupportSessionState.authorizing);
    });

    test('session_ended через сигналинг завершает трансляцию (fail-safe)',
        () async {
      final injected = <Map<String, dynamic>>[];
      final svc = makeService(injected);

      await svc.handleRemoteSignal({'type': 'session_ended'});
      expect(svc.state, SupportSessionState.idle);
      expect(svc.isSharing, isFalse);
    });
  });

  group('A-1: те же команды из DataChannel (DTLS) исполняются', () {
    // handleRemoteInput — точка входа DataChannel (см. _setupDataChannel:
    // channel.onMessage -> handleRemoteInput). Транспорт доверенный,
    // фильтр handleRemoteSignal на него не действует.
    test('mouse_*/key_*/hotkey/text_input исполняются', () async {
      final injected = <Map<String, dynamic>>[];
      final svc = makeService(injected);

      await svc.handleRemoteInput({'type': 'mouse_move', 'x': 0.5, 'y': 0.5});
      await svc.handleRemoteInput({'type': 'mouse_down', 'button': 0});
      await svc.handleRemoteInput({'type': 'key_down', 'key': 'A'});
      await svc.handleRemoteInput({'type': 'hotkey', 'action': 'alt_tab'});
      await svc.handleRemoteInput({'type': 'text_input', 'text': 'ok'});

      final types = injected.map((m) => m['type']).toSet();
      expect(
          types,
          containsAll([
            'mouse_move',
            'mouse_down',
            'key_down',
            'hotkey',
            'text_input'
          ]));
    });

    test('view_only по-прежнему глушит ввод из DataChannel', () async {
      final injected = <Map<String, dynamic>>[];
      final svc = makeService(injected, accessMode: 'view_only');

      await svc.handleRemoteInput({'type': 'mouse_move', 'x': 0.5, 'y': 0.5});
      await svc.handleRemoteInput({'type': 'key_down', 'key': 'A'});
      expect(injected, isEmpty);
    });

    test(
        'serviceHostCommandAllowed остаётся отдельным гейтом (тип из белого списка)',
        () async {
      final injected = <Map<String, dynamic>>[];
      final svc = makeService(injected);

      await svc.handleRemoteInput({'type': 'mouse_wheel', 'deltaY': -2.0});
      expect(injected, isNotEmpty);
      expect(injected.first['type'], 'mouse_wheel');
    });
  });

  group('A-1: классификация типов', () {
    test('signalingAllowedTypes и dataChannelOnlyTypes не пересекаются', () {
      for (final t in SupportService.signalingAllowedTypes) {
        expect(SupportService.dataChannelOnlyTypes, isNot(contains(t)),
            reason: '$t не должен быть одновременно разрешён и запрещён');
      }
    });

    test('набор DataChannel-only покрывает все команды исполнения', () {
      const expected = [
        'mouse_move',
        'mouse_down',
        'mouse_up',
        'mouse_click',
        'click',
        'wheel',
        'mouse_wheel',
        'key_down',
        'key_up',
        'block_input',
        'hotkey',
        'text_input',
        'clipboard_set',
        'clipboard_get',
        'file_start',
        'file_chunk',
        'file_end',
        'file_reject',
        'file_ack',
        'video_quality',
        'reboot',
        'input_control',
      ];
      for (final t in expected) {
        expect(SupportService.dataChannelOnlyTypes, contains(t));
      }
    });
  });
}
