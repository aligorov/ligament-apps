import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:ligament_authenticator/screens/support_operator_screen.dart';

/// Ш3/Ш4 (docs/console-any-state-plan.md): чистые функции экрана консоли —
/// матчинг завершения сессии по двум уровням конверта, статус по стадийным
/// признакам готовности и классификация P2P-состояний для grace-завершения.
void main() {
  group('isSessionTerminatedMessage (Ш4, Д6)', () {
    test('верхний data[type]: session_ended', () {
      expect(isSessionTerminatedMessage({'type': 'session_ended'}), isTrue);
    });

    test('верхний data[type]: support_ended', () {
      expect(isSessionTerminatedMessage({'type': 'support_ended'}), isTrue);
    });

    test('нормализованный payload[type] (как SDP) — data.data обёртка', () {
      expect(
        isSessionTerminatedMessage({
          'data': {'type': 'session_ended'}
        }),
        isTrue,
      );
      expect(
        isSessionTerminatedMessage({
          'data': {'type': 'support_ended'}
        }),
        isTrue,
      );
    });

    test('payload без обёртки data (payload == data) — тоже матчится', () {
      expect(isSessionTerminatedMessage(<String, dynamic>{
        'type': 'session_ended',
        'session_id': 's1',
      }), isTrue);
    });

    test('SDP-предложение не матчится как завершение', () {
      expect(
        isSessionTerminatedMessage({
          'data': {
            'sdp': {'type': 'offer', 'sdp': 'v=0...'}
          }
        }),
        isFalse,
      );
    });

    test('ICE-кандидат не матчится как завершение', () {
      expect(
        isSessionTerminatedMessage({
          'data': {
            'candidate': {
              'candidate': 'candidate:1 1 UDP 2130706431 10.0.0.1 8998 typ host',
              'sdpMid': '0',
            }
          }
        }),
        isFalse,
      );
    });

    test('чужие типы сообщений не матчатся', () {
      expect(isSessionTerminatedMessage({'type': 'screen_list'}), isFalse);
      expect(isSessionTerminatedMessage(<String, dynamic>{}), isFalse);
      expect(
        isSessionTerminatedMessage({
          'data': {'type': 'chat_message'}
        }),
        isFalse,
      );
    });

    test('data.data не-Map (повреждённый конверт) не роняет матчинг', () {
      expect(
        isSessionTerminatedMessage(<String, dynamic>{'data': 'garbage'}),
        isFalse,
      );
      expect(
        isSessionTerminatedMessage(<String, dynamic>{
          'type': 'session_ended',
          'data': 'garbage',
        }),
        isTrue,
      );
    });
  });

  group('consoleConnectionStatusKey (Ш3, §4.3)', () {
    test('P2P + кадр => stream_active («зелёный» статус)', () {
      expect(consoleConnectionStatusKey(true, true), 'stream_active');
    });

    test('track/P2P без кадра => p2p_connected, не stream_active', () {
      expect(consoleConnectionStatusKey(true, false), 'p2p_connected');
    });

    test('кадр без P2P (state flapping) => init, «зелёного» нет', () {
      expect(consoleConnectionStatusKey(false, true), 'init');
    });

    test('WS-only (ничего нет) => init — WS-открытие не даёт «подключено»', () {
      expect(consoleConnectionStatusKey(false, false), 'init');
    });
  });

  group('pcStateRequiresGraceTermination (Ш4)', () {
    test('Failed => grace-завершение', () {
      expect(
        pcStateRequiresGraceTermination(RTCPeerConnectionState.RTCPeerConnectionStateFailed),
        isTrue,
      );
    });

    test('Closed => grace-завершение', () {
      expect(
        pcStateRequiresGraceTermination(RTCPeerConnectionState.RTCPeerConnectionStateClosed),
        isTrue,
      );
    });

    test('Disconnected => НЕ завершаем: ICE restart должен работать', () {
      expect(
        pcStateRequiresGraceTermination(RTCPeerConnectionState.RTCPeerConnectionStateDisconnected),
        isFalse,
      );
    });

    test('Connected/New => не завершаем', () {
      expect(
        pcStateRequiresGraceTermination(RTCPeerConnectionState.RTCPeerConnectionStateConnected),
        isFalse,
      );
      expect(
        pcStateRequiresGraceTermination(RTCPeerConnectionState.RTCPeerConnectionStateNew),
        isFalse,
      );
    });
  });
}
