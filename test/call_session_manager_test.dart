import 'package:flutter_test/flutter_test.dart';
import 'package:ligament_authenticator/services/call_audio_route_service.dart';
import 'package:ligament_authenticator/services/call_session_manager.dart';
import 'package:ligament_authenticator/services/chat_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CallSessionManager State Tests', () {
    setUp(() {
      ChatService.instance.resetForTest();
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

    test('call recording state and toggleRecording callback work properly', () async {
      final manager = CallSessionManager();
      manager.startCall(
        chatId: 'c-rec',
        chatTitle: 'Запись звонка',
        isVideo: false,
      );

      expect(manager.isRecorded, isFalse);
      expect(manager.recorderSessionId, isNull);

      // 1. handleRecordingState updates isRecorded and recorderSessionId
      manager.handleRecordingState(isRecorded: true, recorderSessionId: 'sess-rec-123');
      expect(manager.isRecorded, isTrue);
      expect(manager.recorderSessionId, 'sess-rec-123');

      // 2. toggleRecording calls onToggleRecording callback and updates state from response
      String? toggledCallId;
      bool? toggledRecord;
      manager.onToggleRecording = (callId, {required record, bool isVideo = false}) async {
        toggledCallId = callId;
        toggledRecord = record;
        return {
          'is_recorded': record,
          'recorder_session_id': 'sess-rec-456',
        };
      };

      await manager.toggleRecording();
      expect(toggledCallId, manager.currentCallId);
      expect(toggledRecord, isFalse); // already true, so next is false
      expect(manager.isRecorded, isFalse);
      expect(manager.recorderSessionId, 'sess-rec-456');

      // 3. endCall resets recording state
      manager.endCall();
      expect(manager.isRecorded, isFalse);
      expect(manager.recorderSessionId, isNull);
    });

    test('audio route syncs speaker state from native CallKit and applies correctly', () {
      final route = CallAudioRouteService.instance;
      route.prepareDefaultRoute(isVideo: false);
      expect(route.isSpeaker, isFalse);

      route.updateSpeakerFromNative(true);
      expect(route.isSpeaker, isTrue);

      route.updateSpeakerFromNative(false);
      expect(route.isSpeaker, isFalse);
    });

    test('fingerprintEmojiPalette contains 64 unique emojis (24-bit SAS entropy)', () {
      expect(CallSessionManager.fingerprintEmojiPalette.length, 64);
      expect(CallSessionManager.fingerprintEmojiPalette.toSet().length, 64);
    });

    test('prepareIncomingCall reuses explicit server callId and preserves it on offer', () {
      final manager = CallSessionManager();
      final preparedId = manager.prepareIncomingCall(
        chatId: 'c-push-uuid',
        callerName: 'Alice',
        isVideo: true,
        callId: 'srv-call-uuid-123',
      );

      expect(preparedId, 'srv-call-uuid-123');
      expect(manager.currentCallId, 'srv-call-uuid-123');
      expect(manager.status, CallStatus.incoming);

      manager.handleIncomingOffer(
        fromUser: 'alice',
        chatId: 'c-push-uuid',
        offerPayload: {
          'call_id': 'srv-call-uuid-123',
          'caller_name': 'Alice',
          'is_video': true,
          'sdp': 'v=0\r\no=alice 1 1 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\n',
        },
      );

      expect(manager.currentCallId, 'srv-call-uuid-123');
      expect(manager.status, CallStatus.incoming);
      manager.endCall(notifyPeer: false);
    });

    test('handleIncomingOffer resolves glare (impolite ignores, polite yields, 3rd party gets busy)', () {
      final manager = CallSessionManager();
      final signals = <(String, String, Map<String, dynamic>)>[];
      manager.onSendSignal = (target, chatId, payload) {
        signals.add((target, chatId, payload));
      };

      // 1. Third-party collision during outgoing call -> busy
      ChatService.instance.setCurrentUser('bob');
      manager.startCall(
        chatId: 'c-1',
        chatTitle: 'Alice',
        isVideo: false,
        targetUserId: 'alice',
      );
      manager.handleIncomingOffer(
        fromUser: 'carol',
        chatId: 'c-2',
        offerPayload: {'sdp': 'v=0\r\n'},
      );
      expect(
        signals.any((s) => s.$1 == 'carol' && s.$3['type'] == 'busy' && s.$3['device_busy'] == true),
        isTrue,
      );
      expect(manager.targetUserId, 'alice');
      manager.endCall(notifyPeer: false);
      signals.clear();

      // 2. Impolite peer ('carol' > 'bob') -> ignores same-peer glare offer
      ChatService.instance.setCurrentUser('carol');
      manager.startCall(
        chatId: 'c-cb',
        chatTitle: 'Bob',
        isVideo: false,
        targetUserId: 'bob',
      );
      manager.handleIncomingOffer(
        fromUser: 'bob',
        chatId: 'c-cb',
        offerPayload: {'call_id': 'bob-offer-1', 'sdp': 'v=0\r\n'},
      );
      expect(signals.where((s) => s.$1 == 'bob' && s.$3['type'] == 'ringing'), isEmpty);
      expect(manager.status, CallStatus.calling);
      manager.endCall(notifyPeer: false);
      signals.clear();

      // 3. Polite peer ('alice' < 'bob') -> yields outgoing call and accepts incoming offer
      ChatService.instance.setCurrentUser('alice');
      manager.startCall(
        chatId: 'c-ab',
        chatTitle: 'Bob',
        isVideo: false,
        targetUserId: 'bob',
      );
      manager.handleIncomingOffer(
        fromUser: 'bob',
        chatId: 'c-ab',
        offerPayload: {
          'call_id': 'bob-glare-call',
          'caller_name': 'Bob',
          'is_video': false,
          'sdp': 'v=0\r\no=bob 1 1 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\n',
        },
      );
      expect(
        signals.any((s) => s.$1 == 'bob' && s.$3['type'] == 'ringing'),
        isTrue,
      );
      expect(manager.currentCallId, 'bob-glare-call');
      manager.endCall(notifyPeer: false);
    });
  });
}
