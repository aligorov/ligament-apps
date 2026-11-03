import 'package:flutter_test/flutter_test.dart';
import 'package:ligament_authenticator/services/call_session_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CallSessionManager State Tests', () {
    test('initial state is idle and hidden', () {
      final manager = CallSessionManager();
      expect(manager.status, CallStatus.idle);
      expect(manager.displayMode, CallDisplayMode.hidden);
      expect(manager.isMuted, isFalse);
      expect(manager.isCameraOff, isFalse);
      expect(manager.isScreenSharing, isFalse);
    });

    test('startCall transitions to calling and fullscreen mode', () {
      final manager = CallSessionManager();
      manager.startCall(
        chatId: 'c-test',
        chatTitle: 'Команда Архитектуры',
        isVideo: true,
      );

      expect(manager.status, CallStatus.calling);
      expect(manager.displayMode, CallDisplayMode.fullscreen);
      expect(manager.chatId, 'c-test');
      expect(manager.chatTitle, 'Команда Архитектуры');
      expect(manager.isVideo, isTrue);
    });

    test('setPip toggles between fullscreen and pip without ending call', () {
      final manager = CallSessionManager();
      manager.startCall(
        chatId: 'c-test',
        chatTitle: 'Команда Архитектуры',
        isVideo: true,
      );

      manager.setPip(true);
      expect(manager.displayMode, CallDisplayMode.pip);
      expect(manager.status, CallStatus.calling);

      manager.setPip(false);
      expect(manager.displayMode, CallDisplayMode.fullscreen);
    });

    test('endCall resets state to idle and hidden', () {
      final manager = CallSessionManager();
      manager.startCall(
        chatId: 'c-test',
        chatTitle: 'Команда',
        isVideo: false,
      );

      manager.endCall();
      expect(manager.status, CallStatus.idle);
      expect(manager.displayMode, CallDisplayMode.hidden);
      expect(manager.chatId, isEmpty);
    });

    test('toggling mute and camera works as expected', () {
      final manager = CallSessionManager();
      manager.startCall(
        chatId: 'c-test',
        chatTitle: 'Тест',
        isVideo: true,
      );

      expect(manager.isMuted, isFalse);
      manager.toggleMute();
      expect(manager.isMuted, isTrue);

      expect(manager.isCameraOff, isFalse);
      manager.toggleCamera();
      expect(manager.isCameraOff, isTrue);
    });
  });
}
