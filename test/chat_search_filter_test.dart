import 'package:flutter_test/flutter_test.dart';
import 'package:ligament_authenticator/models/chat_models.dart';
import 'package:ligament_authenticator/services/chat_service.dart';

void main() {
  group('Chat Search and Filter Tests', () {
    final now = DateTime.now();
    final testChats = [
      ChatItem(
        id: 'c1',
        kind: 'direct',
        title: 'Иван Иванов',
        peerUserId: 'iivanov',
        unreadCount: 0,
        updatedAt: now,
      ),
      ChatItem(
        id: 'c2',
        kind: 'group',
        title: 'Команда Backend',
        description: 'Разработка микросервисов',
        unreadCount: 3,
        updatedAt: now,
      ),
      ChatItem(
        id: 'c3',
        kind: 'forum',
        isForum: true,
        title: 'IT Helpdesk',
        unreadCount: 0,
        updatedAt: now,
      ),
      ChatItem(
        id: 'c4',
        kind: 'direct',
        title: 'Анна Сидорова',
        peerUserId: 'asidorova',
        unreadCount: 1,
        updatedAt: now,
      ),
    ];

    test('filters chats by query across title, peerUserId and description', () {
      final resTitle = ChatService.filterChatList(testChats, query: 'Backend');
      expect(resTitle.length, 1);
      expect(resTitle.first.id, 'c2');

      final resPeer = ChatService.filterChatList(testChats, query: 'iivanov');
      expect(resPeer.length, 1);
      expect(resPeer.first.id, 'c1');

      final resDesc = ChatService.filterChatList(testChats, query: 'микросервисов');
      expect(resDesc.length, 1);
      expect(resDesc.first.id, 'c2');

      final resNone = ChatService.filterChatList(testChats, query: 'nonexistent');
      expect(resNone.isEmpty, isTrue);
    });

    test('filters chats by category chip', () {
      final directs = ChatService.filterChatList(testChats, category: 'direct');
      expect(directs.length, 2);
      expect(directs.every((c) => c.kind == 'direct'), isTrue);

      final forums = ChatService.filterChatList(testChats, category: 'forum');
      expect(forums.length, 1);
      expect(forums.first.isForum, isTrue);

      final unread = ChatService.filterChatList(testChats, category: 'unread');
      expect(unread.length, 2);
      expect(unread.every((c) => c.unreadCount > 0), isTrue);

      final all = ChatService.filterChatList(testChats, category: 'all');
      expect(all.length, 4);
    });

    test('combines search query and category filter', () {
      final res = ChatService.filterChatList(
        testChats,
        query: 'Анна',
        category: 'unread',
      );
      expect(res.length, 1);
      expect(res.first.id, 'c4');

      final resEmpty = ChatService.filterChatList(
        testChats,
        query: 'Иван',
        category: 'unread',
      );
      expect(resEmpty.isEmpty, isTrue);
    });
  });
}
