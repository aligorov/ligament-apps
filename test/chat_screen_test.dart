import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ligament_authenticator/models/chat_models.dart';
import 'package:ligament_authenticator/services/call_session_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
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
      (call) async => true,
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('xyz.luan/audioplayers'), null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('xyz.luan/audioplayers.global'), null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('dexterous.com/flutter/local_notifications'), null);
  });

  group('ChatModels Unit Tests', () {
    test('ChatItem deserialization and defaults', () {
      final json = {
        'id': 'chat-123',
        'kind': 'group',
        'title': 'ИТ-Служба',
        'description': 'Канал ИТ-департамента',
        'is_forum': true,
        'unread_count': 5,
        'updated_at': '2026-11-03T10:00:00Z',
      };

      final chat = ChatItem.fromJson(json);
      expect(chat.id, 'chat-123');
      expect(chat.title, 'ИТ-Служба');
      expect(chat.isForum, isTrue);
      expect(chat.unreadCount, 5);
      expect(chat.updatedAt.isUtc, isTrue);
    });

    test('TopicItem deserialization and unread tracking', () {
      final json = {
        'id': 42,
        'chat_id': 'chat-123',
        'title': 'Серверы',
        'icon_emoji': '🖥️',
        'is_general': false,
        'unread_count': 2,
      };

      final topic = TopicItem.fromJson(json);
      expect(topic.id, 42);
      expect(topic.chatId, 'chat-123');
      expect(topic.title, 'Серверы');
      expect(topic.iconEmoji, '🖥️');
      expect(topic.unreadCount, 2);
    });

    test('TopicItem with isPinned, isClosed and copyWith', () {
      final json = {
        'id': 42,
        'chat_id': 'chat-123',
        'title': 'Серверы',
        'icon_emoji': '🖥️',
        'is_general': false,
        'is_closed': true,
        'is_pinned': true,
        'unread_count': 2,
      };

      final topic = TopicItem.fromJson(json);
      expect(topic.isClosed, isTrue);
      expect(topic.isPinned, isTrue);

      final updated = topic.copyWith(title: 'Архив серверов', isClosed: false);
      expect(updated.title, 'Архив серверов');
      expect(updated.isClosed, isFalse);
      expect(updated.isPinned, isTrue);
    });

    test('ChatItem with myRole deserialization and default', () {
      final jsonAdmin = {
        'id': 'chat-123',
        'kind': 'forum',
        'title': 'ИТ-Форум',
        'is_forum': true,
        'my_role': 'admin',
        'updated_at': '2026-11-03T10:00:00Z',
      };
      final chatAdmin = ChatItem.fromJson(jsonAdmin);
      expect(chatAdmin.myRole, 'admin');

      final jsonDefault = {
        'id': 'chat-124',
        'kind': 'group',
        'title': 'Команда',
        'updated_at': '2026-11-03T10:00:00Z',
      };
      final chatDefault = ChatItem.fromJson(jsonDefault);
      expect(chatDefault.myRole, '');
    });

    test('ChatMessage deserialization with secret ttl', () {
      final json = {
        'id': 1001,
        'chat_id': 'chat-123',
        'topic_id': 42,
        'sender_id': 'usr-alex',
        'sender_name': 'Алексей',
        'client_msg_id': 'c-1',
        'body': 'Секретный пароль базы данных',
        'kind': 'secret',
        'secret_ttl_seconds': 60,
        'created_at': '2026-11-03T10:15:00Z',
      };

      final msg = ChatMessage.fromJson(json);
      expect(msg.id, 1001);
      expect(msg.kind, 'secret');
      expect(msg.secretTtlSeconds, 60);
      expect(msg.body, 'Секретный пароль базы данных');
    });

    test('UserPresence deserialization and computed properties', () {
      final jsonVacation = {
        'user_id': 'usr-petr',
        'is_online': false,
        'status': 'vacation',
        'status_text': 'до 20 ноября',
        'updated_at': '2026-11-04T08:00:00Z',
      };
      final presenceVacation = UserPresence.fromJson(jsonVacation);
      expect(presenceVacation.userId, 'usr-petr');
      expect(presenceVacation.status, 'vacation');
      expect(presenceVacation.statusLabel, 'В отпуске');
      expect(presenceVacation.statusEmoji, '🌴');
      expect(presenceVacation.fullStatusDisplay, '🌴 В отпуске (до 20 ноября)');
      expect(presenceVacation.isOnline, isFalse);

      final jsonBusy = {
        'user_id': 'usr-anna',
        'is_online': true,
        'status': 'busy',
        'status_text': 'встреча',
      };
      final presenceBusy = UserPresence.fromJson(jsonBusy);
      expect(presenceBusy.statusLabel, 'Занят');
      expect(presenceBusy.isBusyOrDnd, isTrue);
      expect(presenceBusy.fullStatusDisplay, '🔴 Занят (встреча)');

      final jsonOffline = {
        'user_id': 'usr-offline',
        'is_online': false,
        'status': 'online',
      };
      final presenceOffline = UserPresence.fromJson(jsonOffline);
      // When socket is disconnected and status was 'online', statusLabel is 'Не в сети'
      expect(presenceOffline.statusLabel, 'Не в сети');
      expect(presenceOffline.fullStatusDisplay, 'Не в сети');
    });

    test('ChatContact deserialization with presence status', () {
      final json = {
        'user_id': 'usr-ivan',
        'username': 'ivan_dev',
        'display_name': 'Иван Иванов',
        'email': 'ivan@example.com',
        'department': 'Отдел разработки',
        'status': 'away',
        'status_text': 'Обед',
      };
      final contact = ChatContact.fromJson(json);
      expect(contact.userId, 'usr-ivan');
      expect(contact.status, 'away');
      expect(contact.statusText, 'Обед');
    });

    test('CallSessionManager incoming call transition and reject', () {
      final call = CallSessionManager.instance;
      expect(call.status, CallStatus.idle);
      expect(call.displayMode, CallDisplayMode.hidden);

      // Симуляция входящего звонка
      call.handleIncomingOffer(
        fromUser: 'user_alex',
        chatId: 'chat_123',
        offerPayload: {
          'caller_name': 'Алексей',
          'is_video': true,
          'sdp': 'v=0\r\no=mock...',
        },
      );

      expect(call.status, CallStatus.incoming);
      expect(call.displayMode, CallDisplayMode.fullscreen);
      expect(call.callerName, 'Алексей');
      expect(call.isVideo, isTrue);
      expect(call.chatId, 'chat_123');

      // Отклонение вызова возвращает в idle и скрывает оверлей
      call.rejectIncomingCall();
      expect(call.status, CallStatus.idle);
      expect(call.displayMode, CallDisplayMode.hidden);
    });

    test('ChatMessage deserialization with attachments metadata and fallback', () {
      final jsonWithMeta = {
        'id': 1002,
        'chat_id': 'chat-123',
        'topic_id': 0,
        'sender_id': 'usr-alex',
        'sender_name': 'Алексей',
        'client_msg_id': 'c-2',
        'body': '📷 Изображение.png',
        'kind': 'image',
        'metadata': {
          'attachments': [
            {
              'id': 'att-12345',
              'name': 'Изображение.png',
              'size': 1363148,
              'content_type': 'image/png',
            }
          ]
        },
        'created_at': '2026-11-04T16:09:00Z',
      };

      final msg = ChatMessage.fromJson(jsonWithMeta);
      expect(msg.hasAttachments, isTrue);
      expect(msg.attachments.length, 1);
      expect(msg.attachments.first['id'], 'att-12345');
      expect(msg.attachments.first['name'], 'Изображение.png');
      expect(msg.attachments.first['size'], 1363148);
      expect(msg.attachments.first['content_type'], 'image/png');
    });

    test('ChatMessage deserialization with video attachment', () {
      final jsonVideo = {
        'id': 1003,
        'chat_id': 'chat-123',
        'topic_id': 0,
        'sender_id': 'usr-alex',
        'sender_name': 'Алексей',
        'client_msg_id': 'c-3',
        'body': '🎥 screencast.mp4',
        'kind': 'video',
        'metadata': {
          'attachments': [
            {
              'id': 'att-video-999',
              'name': 'screencast.mp4',
              'size': 14890000,
              'content_type': 'video/mp4',
            }
          ]
        },
        'created_at': '2026-11-04T16:15:00Z',
      };

      final msg = ChatMessage.fromJson(jsonVideo);
      expect(msg.hasAttachments, isTrue);
      expect(msg.kind, 'video');
      expect(msg.attachments.first['id'], 'att-video-999');
      expect(msg.attachments.first['name'], 'screencast.mp4');
      expect(msg.attachments.first['size'], 14890000);
      expect(msg.attachments.first['content_type'], 'video/mp4');
    });
  });
}
