import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ligament_authenticator/services/push_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PushService Unit Tests', () {
    late PushService pushService;
    final List<MethodCall> nativeCalls = [];

    setUp(() {
      pushService = PushService();
      nativeCalls.clear();

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('ligament/push'),
        (MethodCall methodCall) async {
          nativeCalls.add(methodCall);
          if (methodCall.method == 'registerForPush') {
            return {'status': 'granted', 'token': 'mock-device-token-12345'};
          }
          if (methodCall.method == 'getInitialNotification') {
            return {
              'action': 'APPROVE',
              'payload': {
                'challenge_id': 'chal-init-999',
                'service': 'Corporate VPN',
              },
            };
          }
          if (methodCall.method == 'getPushToken') {
            return 'mock-device-token-12345';
          }
          return null;
        },
      );
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('ligament/push'), null);
    });

    test('calls registerForPush and parses initial token and action', () async {
      String? receivedToken;
      String? actionReceived;
      String? challengeReceived;

      pushService.onPushToken = (token) => receivedToken = token;
      pushService.onNotificationAction = (action, cid, payload) {
        actionReceived = action;
        challengeReceived = cid;
      };

      await pushService.init();

      expect(pushService.pushToken, equals('mock-device-token-12345'));
      expect(receivedToken, equals('mock-device-token-12345'));
      expect(actionReceived, equals('APPROVE'));
      expect(challengeReceived, equals('chal-init-999'));
    });

    test('handles incoming onRemoteNotification callback', () async {
      Map<String, dynamic>? promptPayload;
      pushService.onRemoteNotification = (payload) => promptPayload = payload;

      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const channel = MethodChannel('ligament/push');

      await messenger.handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(
          const MethodCall('onRemoteNotification', {
            'challenge_id': 'chal-remote-123',
            'service': 'SSO Portal',
            'number_match': '84',
          }),
        ),
        (data) {},
      );

      expect(promptPayload, isNotNull);
      expect(promptPayload?['challenge_id'], equals('chal-remote-123'));
      expect(promptPayload?['number_match'], equals('84'));
    });

    test('handles incoming onNotificationAction callback for DENY', () async {
      String? actionTaken;
      String? chalId;

      pushService.onNotificationAction = (action, cid, payload) {
        actionTaken = action;
        chalId = cid;
      };

      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const channel = MethodChannel('ligament/push');

      await messenger.handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(
          const MethodCall('onNotificationAction', {
            'action': 'DENY',
            'payload': {
              'challenge_id': 'chal-deny-456',
            },
          }),
        ),
        (data) {},
      );

      expect(actionTaken, equals('DENY'));
      expect(chalId, equals('chal-deny-456'));
    });
  });
}
