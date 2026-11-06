import 'package:flutter_test/flutter_test.dart';
import 'package:ligament_authenticator/services/call_session_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CallSessionManager State Tests', () {
    setUp(() {
      CallSessionManager().endCall();
    });
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

    test('audio routing defaults and toggle behavior', () async {
      final manager = CallSessionManager();
      manager.startCall(
        chatId: 'c-audio',
        chatTitle: 'Аудио Тест',
        isVideo: false,
      );

      // Для аудиозвонка по умолчанию спикерфон выключен (слуховой динамик у уха)
      expect(manager.isSpeakerphoneOn, isFalse);
      await manager.toggleSpeakerphone();
      expect(manager.isSpeakerphoneOn, isTrue);
      await manager.toggleSpeakerphone();
      expect(manager.isSpeakerphoneOn, isFalse);

      manager.endCall();

      // Для видеозвонка по умолчанию громкая связь
      manager.startCall(
        chatId: 'c-video',
        chatTitle: 'Видео Тест',
        isVideo: true,
      );
      expect(manager.isSpeakerphoneOn, isTrue);
      manager.endCall();
    });

    test('signaling transitions for ringing, offline, and busy', () {
      final manager = CallSessionManager();
      manager.startCall(
        chatId: 'c-signals',
        chatTitle: 'Сигналинг',
        isVideo: false,
      );

      expect(manager.status, CallStatus.calling);

      // Доставка вызова абоненту
      manager.handleRinging();
      expect(manager.status, CallStatus.ringing);

      // Абонент занят
      manager.handleBusy();
      expect(manager.status, CallStatus.ended);

      // Новый звонок: абонент оффлайн
      manager.startCall(
        chatId: 'c-offline',
        chatTitle: 'Оффлайн',
        isVideo: false,
      );
      manager.handleOffline();
      expect(manager.status, CallStatus.offline);

      manager.endCall();
      expect(manager.status, CallStatus.idle);
    });

    test('CallKit UUID lifecycle and incoming offer handling', () {
      final manager = CallSessionManager();
      expect(manager.currentCallId, isEmpty);

      // Incoming offer generates call UUID
      manager.handleIncomingOffer(
        fromUser: 'u-alice',
        chatId: 'c-100',
        offerPayload: {
          'caller_name': 'Алиса',
          'is_video': true,
          'sdp': 'v=0\r\no=alice 123 456 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\n',
        },
      );

      expect(manager.status, CallStatus.incoming);
      expect(manager.currentCallId, isNotEmpty);
      expect(manager.callerName, 'Алиса');
      expect(manager.isVideo, isTrue);

      // Rejection clears call
      manager.rejectIncomingCall();
      expect(manager.status, CallStatus.idle);
      expect(manager.currentCallId, isEmpty);
    });

    test('acceptIncomingCall is idempotent against duplicate invocations', () {
      final manager = CallSessionManager();
      manager.handleIncomingOffer(
        fromUser: 'u-bob',
        chatId: 'c-200',
        offerPayload: {
          'caller_name': 'Боб',
          'is_video': true,
          'sdp': 'v=0\r\no=bob 123 456 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\n',
        },
      );

      final callId = manager.currentCallId;
      // Первое принятие
      manager.acceptIncomingCall();
      expect(manager.status, CallStatus.calling);
      expect(manager.isSpeakerphoneOn, isTrue);

      // Повторное принятие (например, дубликат из Notification + Intent) не сбрасывает вызов
      manager.acceptIncomingCall();
      expect(manager.currentCallId, callId);
      expect(manager.status, CallStatus.calling);

      manager.endCall();
    });

    test('optimizeOpusSdp injects in-band FEC and DTX into SDP', () {
      const rawSdp = 'v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=rtpmap:111 opus/48000/2\r\na=fmtp:111 minptime=10\r\n';
      final optimized = CallSessionManager.optimizeOpusSdp(rawSdp);

      expect(optimized, contains('useinbandfec=1'));
      expect(optimized, contains('usedtx=1'));
      expect(optimized, contains('maxaveragebitrate=24000'));
      expect(optimized, contains('stereo=0'));

      // Идемпотентность: повторный вызов не дублирует флаги
      final doubleOptimized = CallSessionManager.optimizeOpusSdp(optimized);
      expect('useinbandfec=1'.allMatches(doubleOptimized).length, 1);
      expect('usedtx=1'.allMatches(doubleOptimized).length, 1);
    });

    test('optimizeOpusSdp handles SDP with existing useinbandfec=1 without skipping usedtx', () {
      const webrtcDefaultSdp = 'v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=rtpmap:111 opus/48000/2\r\na=fmtp:111 minptime=10;useinbandfec=1\r\n';
      final optimized = CallSessionManager.optimizeOpusSdp(webrtcDefaultSdp);

      expect(optimized, contains('useinbandfec=1'));
      expect(optimized, contains('usedtx=1'));
      expect(optimized, contains('maxaveragebitrate=24000'));
      expect(optimized, contains('stereo=0'));
      expect('useinbandfec=1'.allMatches(optimized).length, 1);
    });

    test('callFingerprintEmojis generates symmetric 4-emoji fingerprint from DTLS', () {
      final manager = CallSessionManager();
      const sdpAlice = 'v=0\r\na=fingerprint:sha-256 AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99\r\n';
      const sdpBob = 'v=0\r\na=fingerprint:sha-256 99:88:77:66:55:44:33:22:11:00:FF:EE:DD:CC:BB:AA:99:88:77:66:55:44:33:22:11:00:FF:EE:DD:CC:BB:AA\r\n';

      // 1. При отсутствии SDP список эмодзи пуст
      manager.setSdpForTesting(local: '', remote: '');
      expect(manager.callFingerprintEmojis, isEmpty);

      // 2. С установленными SDP формируются 4 эмодзи
      manager.setSdpForTesting(local: sdpAlice, remote: sdpBob);
      final emojisAlice = manager.callFingerprintEmojis;
      expect(emojisAlice.length, 4);

      // 3. Симметрия: у Боба (обратный порядок local/remote) получается ровно тот же набор 4 эмодзи
      manager.setSdpForTesting(local: sdpBob, remote: sdpAlice);
      final emojisBob = manager.callFingerprintEmojis;
      expect(emojisBob, equals(emojisAlice));
    });
  });
}
