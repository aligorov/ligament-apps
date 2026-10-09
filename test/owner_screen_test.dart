import 'package:flutter_test/flutter_test.dart';
import 'package:ligament_authenticator/services/auth_state.dart';
import 'package:ligament_authenticator/services/support_service.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

/// no-op wakelock: stopScreenSharing вызывает WakelockPlus.disable() — в
/// тестах платформенного канала нет, асинхронный PlatformException ронял
/// бы тест ПОСЛЕ его завершения.
class _NoopWakelock extends WakelockPlusPlatformInterface {
  @override
  Future<void> toggle({required bool enable}) async {}
}

/// Этап 2.4 «Экран» (план §5.2): owner-флаг сессии. Обычный SOS не должен
/// менять поведение — ownerSession по умолчанию false и сбрасывается при
/// переходах жизненного цикла; owner-сессия отличается в UI (баннер,
/// заголовок viewer'а «Мой ПК», тексты ошибок).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  WakelockPlusPlatformInterface.instance = _NoopWakelock();

  group('SupportService ownerSession (этап 2.4)', () {
    test('по умолчанию false — обычный SOS не задевает owner-ветки UI', () {
      final s = SupportService();
      addTearDown(s.dispose);
      expect(s.ownerSession, isFalse);
      expect(s.ownerInitiatorDevice, isNull);
    });

    test('setAuthorizing(owner: true) выставляет флаг и инициатора', () {
      final s = SupportService();
      addTearDown(s.dispose);
      s.setAuthorizing(
        sessionId: 'sess-1',
        accessMode: 'full_control',
        owner: true,
        initiatorDevice: 'iPhone А.И.',
      );
      expect(s.ownerSession, isTrue);
      expect(s.ownerInitiatorDevice, 'iPhone А.И.');
      expect(s.state, SupportSessionState.authorizing);
      expect(s.activeSessionId, 'sess-1');
    });

    test('setAuthorizing без owner (SOS-путь) не включает owner-режим', () {
      final s = SupportService();
      addTearDown(s.dispose);
      s.setAuthorizing(
        sessionId: 'sos-1',
        accessMode: 'view_only',
      );
      expect(s.ownerSession, isFalse);
      expect(s.ownerInitiatorDevice, isNull);
    });

    test('setRequested сбрасывает owner-флаг (новое SOS-обращение)', () {
      final s = SupportService();
      addTearDown(s.dispose);
      s.setAuthorizing(sessionId: 'a', owner: true, initiatorDevice: 'Phone');
      s.setRequested(
        sessionId: 'b',
        category: 'it',
        problemSummary: 'help',
      );
      expect(s.ownerSession, isFalse);
      expect(s.ownerInitiatorDevice, isNull);
    });

    test('stopScreenSharing сбрасывает owner-флаг (конец трансляции)', () async {
      final s = SupportService();
      addTearDown(s.dispose);
      s.setAuthorizing(sessionId: 'a', owner: true, initiatorDevice: 'Phone');
      await s.stopScreenSharing();
      expect(s.ownerSession, isFalse);
      expect(s.ownerInitiatorDevice, isNull);
      expect(s.state, SupportSessionState.idle);
    });
  });

  group('ownerScreenPromptTargetsThisDevice — адресация prompt (этап 2.4)', () {
    test('без target_device_id (широковещательная рассылка) — наша машина цель', () {
      expect(
        ownerScreenPromptTargetsThisDevice(
          {'session_id': 's1', 'initiator_device_id': 'dev-viewer'},
          'dev-pc',
        ),
        isTrue,
      );
    });

    test('target_device_id == наш device_id — это моя машина, транслируем', () {
      expect(
        ownerScreenPromptTargetsThisDevice(
          {'session_id': 's1', 'target_device_id': 'dev-pc'},
          'dev-pc',
        ),
        isTrue,
      );
    });

    test('target_device_id != наш device_id — НЕ моя машина, игнорируем', () {
      expect(
        ownerScreenPromptTargetsThisDevice(
          {'session_id': 's1', 'target_device_id': 'dev-agent-other'},
          'dev-pc',
        ),
        isFalse,
      );
    });

    test('пустой target_device_id не адресует точечно (legacy-сервер)', () {
      expect(
        ownerScreenPromptTargetsThisDevice(
          {'session_id': 's1', 'target_device_id': ''},
          'dev-pc',
        ),
        isTrue,
      );
    });

    test('наш device_id неизвестен: точечный адрес — не нам, broadcast — нам', () {
      expect(
        ownerScreenPromptTargetsThisDevice(
          {'session_id': 's1', 'target_device_id': 'dev-agent'},
          null,
        ),
        isFalse,
      );
      expect(
        ownerScreenPromptTargetsThisDevice({'session_id': 's1'}, null),
        isTrue,
      );
    });

    test('инициатор — мы сами: viewer, экран не транслирует (и с target)', () {
      expect(
        ownerScreenPromptTargetsThisDevice(
          {'session_id': 's1', 'initiator_device_id': 'dev-me'},
          'dev-me',
        ),
        isFalse,
      );
      // Точечный адрес перевешивает только при несовпадении; здесь цель —
      // другой агент, а мы и так viewer.
      expect(
        ownerScreenPromptTargetsThisDevice(
          {'session_id': 's1', 'initiator_device_id': 'dev-me', 'target_device_id': 'dev-pc'},
          'dev-me',
        ),
        isFalse,
      );
    });

    test('target_machine_id совпадает с зарегистрированной машиной — транслируем даже при несовпадении device_id', () {
      expect(
        ownerScreenPromptTargetsThisDevice(
          {
            'session_id': 's1',
            'initiator_device_id': 'dev-viewer',
            'target_device_id': 'old-dev-id',
            'target_machine_id': 'machine-123',
          },
          'new-dev-id',
          'machine-123',
        ),
        isTrue,
      );
    });

    test('target_machine_id другой машины — игнорируем', () {
      expect(
        ownerScreenPromptTargetsThisDevice(
          {
            'session_id': 's1',
            'initiator_device_id': 'dev-viewer',
            'target_machine_id': 'other-machine-456',
          },
          'my-dev-id',
          'machine-123',
        ),
        isFalse,
      );
    });
  });
}
