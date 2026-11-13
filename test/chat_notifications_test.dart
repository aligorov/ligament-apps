import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ligament_authenticator/api/client.dart';
import 'package:ligament_authenticator/models/chat_models.dart';
import 'package:ligament_authenticator/screens/chat_screen.dart';
import 'package:ligament_authenticator/services/alert_service.dart';
import 'package:ligament_authenticator/services/auth_state.dart';
import 'package:ligament_authenticator/services/call_session_manager.dart';
import 'package:ligament_authenticator/services/chat_service.dart';
import 'package:provider/provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final localNotificationCalls = <MethodCall>[];

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('xyz.luan/audioplayers'),
      (call) async => call.method == 'create' ? 'test-player' : null,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('xyz.luan/audioplayers.global'),
      (call) async => null,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('dexterous.com/flutter/local_notifications'),
      (call) async {
        localNotificationCalls.add(call);
        return true;
      },
    );
  });

  setUp(() {
    localNotificationCalls.clear();
    ChatService.instance.resetForTest();
    CallSessionManager.instance.endCall(notifyPeer: false);
  });

  tearDown(() {
    ChatService.instance.resetForTest();
    CallSessionManager.instance.endCall(notifyPeer: false);
  });

  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('xyz.luan/audioplayers'), null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('xyz.luan/audioplayers.global'), null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('dexterous.com/flutter/local_notifications'), null);
  });

  group('ChatService notification & message deduplication', () {
    test('deduplicates repeated chat.message WS events by id and ignores self unread increment', () async {
      final chat = ChatItem.fromJson(const {
        'id': 'chat-dedup',
        'kind': 'direct',
        'title': 'Alice',
        'peer_user_id': 'alice',
        'unread_count': 0,
        'my_role': 'member',
        'updated_at': '2026-11-12T10:00:00Z',
      });
      final service = ChatService.instance;
      service.setChatsForTest([chat]);
      service.setCurrentUser('bob');
      service.setActiveChat(null);

      final incomingEvent = {
        'type': 'chat.message',
        'payload': {
          'message': {
            'id': 501,
            'chat_id': 'chat-dedup',
            'topic_id': 0,
            'sender_id': 'alice',
            'sender_name': 'Alice',
            'client_msg_id': 'msg-501',
            'body': 'Привет!',
            'kind': 'text',
            'created_at': '2026-11-12T10:01:00Z',
          },
        },
      };

      // Повторное событие (из room broadcast + direct user_event) должно дедуплицироваться.
      service.onWebSocketEvent(incomingEvent);
      service.onWebSocketEvent(incomingEvent);

      expect(service.getMessages('chat-dedup', 0).length, 1);
      expect(service.chats.single.unreadCount, 1);
      expect(service.chats.single.peerUserId, 'alice');
      expect(service.chats.single.myRole, 'member');

      // Эхо собственного сообщения не должно увеличивать счётчик непрочитанных.
      service.onWebSocketEvent({
        'type': 'chat.message',
        'payload': {
          'message': {
            'id': 502,
            'chat_id': 'chat-dedup',
            'topic_id': 0,
            'sender_id': 'bob',
            'sender_name': 'Bob',
            'client_msg_id': 'msg-502',
            'body': 'Ответил',
            'kind': 'text',
            'created_at': '2026-11-12T10:02:00Z',
          },
        },
      });

      expect(service.getMessages('chat-dedup', 0).length, 2);
      expect(service.chats.single.unreadCount, 1);

      await pumpEventQueue(times: 20);
    });

    test('AlertService deduplicates identical chat notifications within 5s window', () async {
      await AlertService.instance.init();
      localNotificationCalls.clear();

      await AlertService.instance.triggerChatUnreadNotification(
        title: 'Alice',
        body: 'Пропущенный вызов тест',
        chatId: 'chat-alert-1',
      );
      await AlertService.instance.triggerChatUnreadNotification(
        title: 'Alice',
        body: 'Пропущенный вызов тест',
        chatId: 'chat-alert-1',
      );
      await AlertService.instance.triggerChatUnreadNotification(
        title: 'Bob',
        body: 'Пропущенный вызов тест',
        chatId: 'chat-alert-2',
      );

      final showCalls = localNotificationCalls.where((c) => c.method == 'show').toList();
      expect(showCalls.length, 2);
    });

    test('sendMessage does not duplicate message when WebSocket echo arrives before HTTP response', () async {
      final service = ChatService.instance;
      service.setCurrentUser('bob');
      final client = _ChatTestApiClient();

      // Имитируем ситуацию, когда сервер через WebSocket эхо присылает сообщение РАНЬШЕ,
      // чем завершится чтение ответа HTTP POST запроса
      client.onSendInvoked = () {
        service.onWebSocketEvent({
          'type': 'chat.message',
          'payload': {
            'message': {
              'id': 999,
              'chat_id': 'chat-race',
              'topic_id': 0,
              'sender_id': 'bob',
              'sender_name': 'Bob',
              'client_msg_id': 'cmsg_race_999',
              'body': 'Привет из гонки',
              'kind': 'text',
              'created_at': '2026-11-13T12:00:00Z',
            },
          },
        });
      };

      client.mockSendResponse = {
        'id': 999,
        'chat_id': 'chat-race',
        'topic_id': 0,
        'sender_id': 'bob',
        'sender_name': 'Bob',
        'client_msg_id': 'cmsg_race_999',
        'body': 'Привет из гонки',
        'kind': 'text',
        'created_at': '2026-11-13T12:00:00Z',
      };

      await service.sendMessage(
        client,
        'chat-race',
        topicId: 0,
        body: 'Привет из гонки',
        clientMsgId: 'cmsg_race_999',
      );

      final messages = service.getMessages('chat-race', 0);
      expect(messages.length, 1, reason: 'Сообщение должно отображаться ровно 1 раз без дубликатов');
      expect(messages.first.id, 999);
      expect(messages.first.body, 'Привет из гонки');
    });

    test('sendMessage does not duplicate message when WebSocket echo arrives after HTTP response', () async {
      final service = ChatService.instance;
      service.setCurrentUser('bob');
      final client = _ChatTestApiClient();

      client.mockSendResponse = {
        'id': 1000,
        'chat_id': 'chat-race-2',
        'topic_id': 0,
        'sender_id': 'bob',
        'sender_name': 'Bob',
        'client_msg_id': 'cmsg_race_1000',
        'body': 'Второе сообщение',
        'kind': 'text',
        'created_at': '2026-11-13T12:01:00Z',
      };

      await service.sendMessage(
        client,
        'chat-race-2',
        topicId: 0,
        body: 'Второе сообщение',
        clientMsgId: 'cmsg_race_1000',
      );

      // Теперь эхо из WebSocket приходит ПОСЛЕ завершения HTTP запроса
      service.onWebSocketEvent({
        'type': 'chat.message',
        'payload': {
          'message': {
            'id': 1000,
            'chat_id': 'chat-race-2',
            'topic_id': 0,
            'sender_id': 'bob',
            'sender_name': 'Bob',
            'client_msg_id': 'cmsg_race_1000',
            'body': 'Второе сообщение',
            'kind': 'text',
            'created_at': '2026-11-13T12:01:00Z',
          },
        },
      });

      final messages = service.getMessages('chat-race-2', 0);
      expect(messages.length, 1, reason: 'Сообщение должно оставаться ровно 1 раз');
      expect(messages.first.id, 1000);
    });

    test('getMessages defensively deduplicates messages with duplicate ids', () {
      final service = ChatService.instance;
      final msg1 = ChatMessage.fromJson({
        'id': 1001,
        'chat_id': 'chat-dupe-check',
        'topic_id': 0,
        'sender_id': 'bob',
        'sender_name': 'Bob',
        'client_msg_id': 'cmsg_1',
        'body': 'Тест дубля',
        'kind': 'text',
        'created_at': '2026-11-13T12:02:00Z',
      });
      final msg2 = ChatMessage.fromJson({
        'id': 1001,
        'chat_id': 'chat-dupe-check',
        'topic_id': 0,
        'sender_id': 'bob',
        'sender_name': 'Bob',
        'client_msg_id': 'cmsg_1',
        'body': 'Тест дубля',
        'kind': 'text',
        'created_at': '2026-11-13T12:02:00Z',
      });

      service.setMessagesForTest('chat-dupe-check', 0, [msg1, msg2]);
      final deduped = service.getMessages('chat-dupe-check', 0);
      expect(deduped.length, 1);
      expect(deduped.first.id, 1001);
    });
  });

  group('Missed call link_call model & ChatScreen UI', () {
    test('ChatMessage parses link_call metadata for audio and video missed calls', () {
      final audioMissed = ChatMessage.fromJson({
        'id': 601,
        'chat_id': 'chat-direct-1',
        'topic_id': 0,
        'sender_id': 'alice',
        'sender_name': 'Alice',
        'client_msg_id': 'call_missed_audio_1',
        'body': '📞 Пропущенный звонок',
        'kind': 'link_call',
        'metadata': {'call_status': 'missed', 'is_video': false},
        'created_at': '2026-11-12T10:05:00Z',
      });
      final videoMissed = ChatMessage.fromJson({
        'id': 602,
        'chat_id': 'chat-direct-1',
        'topic_id': 0,
        'sender_id': 'alice',
        'sender_name': 'Alice',
        'client_msg_id': 'call_missed_video_1',
        'body': '📹 Пропущенный видеозвонок',
        'kind': 'link_call',
        'metadata': {'call_status': 'missed', 'is_video': true},
        'created_at': '2026-11-12T10:06:00Z',
      });

      expect(audioMissed.kind, 'link_call');
      expect(audioMissed.metadata['call_status'], 'missed');
      expect(audioMissed.metadata['is_video'], isFalse);
      expect(videoMissed.kind, 'link_call');
      expect(videoMissed.metadata['is_video'], isTrue);
    });

    testWidgets('ChatScreen renders missed link_call bubble and starts callback on tap', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final auth = AuthState();
      final directChat = ChatItem.fromJson(const {
        'id': 'chat-direct-1',
        'kind': 'direct',
        'title': 'Alice',
        'peer_user_id': 'alice',
        'unread_count': 0,
        'updated_at': '2026-11-12T10:05:00Z',
      });

      ChatService.instance.setChatsForTest([directChat]);
      ChatService.instance.setCurrentUser('bob');
      ChatService.instance.onWebSocketEvent({
        'type': 'chat.message',
        'payload': {
          'message': {
            'id': 701,
            'chat_id': 'chat-direct-1',
            'topic_id': 0,
            'sender_id': 'alice',
            'sender_name': 'Alice',
            'client_msg_id': 'call_missed_701',
            'body': '📞 Пропущенный звонок',
            'kind': 'link_call',
            'metadata': {'call_status': 'missed', 'is_video': false},
            'created_at': '2026-11-12T10:05:00Z',
          },
        },
      });

      await tester.pumpWidget(
        ChangeNotifierProvider<AuthState>.value(
          value: auth,
          child: const MaterialApp(
            home: ChatScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Выбираем диалог в левой панели, если на широком экране он ещё не выбран автоматически.
      if (find.text('📞 Пропущенный звонок').evaluate().isEmpty) {
        await tester.tap(find.text('Alice').first);
        await tester.pumpAndSettle();
      }

      expect(find.text('📞 Пропущенный звонок'), findsOneWidget);
      expect(find.byIcon(Icons.phone_missed_outlined), findsOneWidget);
      expect(find.text('Перезвонить'), findsOneWidget);

      await tester.tap(find.text('Перезвонить'));
      await tester.pump();

      expect(CallSessionManager.instance.status, CallStatus.calling);
      expect(CallSessionManager.instance.chatId, 'chat-direct-1');
      expect(CallSessionManager.instance.targetUserId, 'alice');
      expect(CallSessionManager.instance.isVideo, isFalse);

      CallSessionManager.instance.endCall(notifyPeer: false);
      await tester.pump();
    });
  });
}

class _ChatTestApiClient extends ApiClient {
  _ChatTestApiClient() : super(baseUrl: 'https://test.example', token: 'test-token');

  Map<String, dynamic>? mockSendResponse;
  void Function()? onSendInvoked;

  @override
  Future<Map<String, dynamic>> sendChatMessage(
    String chatId, {
    int topicId = 0,
    required String body,
    String kind = 'text',
    int? replyToId,
    int? forwardMessageId,
    int? secretTtl,
    Map<String, dynamic>? metadata,
    List<String>? attachments,
    String? clientMsgId,
  }) async {
    onSendInvoked?.call();
    return mockSendResponse ?? {
      'id': 777,
      'chat_id': chatId,
      'topic_id': topicId,
      'sender_id': 'bob',
      'sender_name': 'Bob',
      'client_msg_id': clientMsgId ?? 'test-msg-777',
      'body': body,
      'kind': kind,
      'created_at': DateTime.now().toIso8601String(),
    };
  }
}
