import 'package:flutter_test/flutter_test.dart';
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
}
