import 'package:flutter_test/flutter_test.dart';
import 'package:ligament_authenticator/models/chat_models.dart';

void main() {
  group('Chat Composer and Reply Tests', () {
    test('ChatMessage models replyToId correctly', () {
      final parentMsg = ChatMessage(
        id: 101,
        chatId: 'c1',
        senderId: 'u1',
        senderName: 'Иван',
        clientMsgId: 'm1',
        body: 'Исходный вопрос',
        createdAt: DateTime.now(),
      );

      final replyMsg = ChatMessage(
        id: 102,
        chatId: 'c1',
        senderId: 'u2',
        senderName: 'Ольга',
        clientMsgId: 'm2',
        replyToId: parentMsg.id,
        body: 'Ответ на вопрос',
        createdAt: DateTime.now(),
      );

      expect(replyMsg.replyToId, 101);
      expect(replyMsg.body, 'Ответ на вопрос');
    });

    test('drafts management maintains separate drafts per chat topic', () {
      final drafts = <String, String>{};

      // Сохранение черновика для чата 1 топик 0
      drafts['c1:0'] = 'Недописанный текст в c1';

      // Сохранение черновика для чата 2 топик 42
      drafts['c2:42'] = 'Черновик в форуме c2';

      expect(drafts['c1:0'], 'Недописанный текст в c1');
      expect(drafts['c2:42'], 'Черновик в форуме c2');
      expect(drafts['c1:42'], isNull);
    });
  });
}
