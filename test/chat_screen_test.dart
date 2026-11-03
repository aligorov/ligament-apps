import 'package:flutter_test/flutter_test.dart';
import 'package:ligament_authenticator/models/chat_models.dart';

void main() {
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
  });
}
