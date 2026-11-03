import 'dart:async';
import 'package:flutter/foundation.dart';
import '../api/client.dart';
import '../models/chat_models.dart';
import 'debug_log_service.dart';

class ChatService extends ChangeNotifier {
  static final ChatService instance = ChatService._();
  ChatService._();

  List<ChatItem> _chats = const [];
  List<ChatContact> _contacts = const [];
  final Map<String, List<TopicItem>> _topics = {};
  final Map<String, List<ChatMessage>> _messages = {}; // key: "$chatId:$topicId"
  bool _isLoadingChats = false;
  final Set<String> _loadingMessages = {};

  List<ChatItem> get chats => _chats;
  List<ChatContact> get contacts => _contacts;
  bool get isLoadingChats => _isLoadingChats;

  int get totalUnreadCount {
    var count = 0;
    for (final c in _chats) {
      count += c.unreadCount;
    }
    return count;
  }

  List<TopicItem> getTopics(String chatId) => _topics[chatId] ?? const [];
  List<ChatMessage> getMessages(String chatId, int topicId) =>
      _messages['$chatId:$topicId'] ?? const [];

  Future<void> loadChats(ApiClient client) async {
    _isLoadingChats = true;
    notifyListeners();
    try {
      final list = await client.getChats();
      _chats = list.map(ChatItem.fromJson).toList();
      DebugLogService.instance.record('chat.chats.loaded', fields: {'count': _chats.length});
    } catch (e) {
      DebugLogService.instance.record('chat.chats.failed', error: e);
    } finally {
      _isLoadingChats = false;
      notifyListeners();
    }
  }

  Future<List<TopicItem>> loadTopics(ApiClient client, String chatId) async {
    try {
      final list = await client.getChatTopics(chatId);
      final topics = list.map(TopicItem.fromJson).toList();
      _topics[chatId] = topics;
      notifyListeners();
      return topics;
    } catch (e) {
      DebugLogService.instance.record('chat.topics.failed', error: e, fields: {'chat_id': chatId});
      return [];
    }
  }

  Future<List<ChatContact>> loadContacts(ApiClient client) async {
    try {
      final list = await client.getChatContacts();
      _contacts = list.map(ChatContact.fromJson).toList();
      notifyListeners();
      return _contacts;
    } catch (e) {
      DebugLogService.instance.record('chat.contacts.failed', error: e);
      return [];
    }
  }

  Future<ChatItem> createDirectChat(ApiClient client, String targetUser) async {
    final res = await client.createChat(kind: 'direct', targetUser: targetUser);
    final item = ChatItem.fromJson(res);
    await loadChats(client);
    return item;
  }

  Future<ChatItem> createGroupChat(
    ApiClient client, {
    required String title,
    String description = '',
    bool isForum = false,
  }) async {
    final res = await client.createChat(
      kind: isForum ? 'forum' : 'group',
      title: title,
      description: description,
      isForum: isForum,
    );
    final item = ChatItem.fromJson(res);
    await loadChats(client);
    return item;
  }

  Future<void> loadMessages(
    ApiClient client,
    String chatId, {
    int topicId = 0,
    bool loadMore = false,
  }) async {
    final key = '$chatId:$topicId';
    if (_loadingMessages.contains(key)) return;

    final current = _messages[key] ?? const [];
    var beforeId = 0;
    if (loadMore && current.isNotEmpty) {
      // Самое старое сообщение находится в конце списка (reverse: true)
      beforeId = current.last.id;
    }

    _loadingMessages.add(key);
    try {
      final list = await client.getChatMessages(
        chatId,
        topicId: topicId,
        beforeId: beforeId,
        limit: 40,
      );
      final fetched = list.map(ChatMessage.fromJson).toList();
      // Сервер отдаёт сообщения по id ASC (хронологически: 1, 2, 3...)
      // В reverse: true списке индекс 0 должен быть самым НОВЫМ (последним по времени)
      // Поэтому разворачиваем пачку: индекс 0 = новейшее
      final reversedBatch = fetched.reversed.toList();

      if (loadMore) {
        // Добавляем старые сообщения в конец массива:
        // В reverse: true списке это не сдвигает текущую позицию скролла!
        _messages[key] = [...current, ...reversedBatch];
      } else {
        _messages[key] = reversedBatch;
      }

      if (current.isEmpty && fetched.isNotEmpty) {
        // Сдвигаем read pointer на самое свежее сообщение
        final latest = fetched.last;
        unawaited(markRead(client, chatId, topicId, latest.id));
      }
      notifyListeners();
    } catch (e) {
      DebugLogService.instance.record('chat.messages.failed', error: e, fields: {'key': key});
    } finally {
      _loadingMessages.remove(key);
    }
  }

  Future<void> sendMessage(
    ApiClient client,
    String chatId, {
    int topicId = 0,
    required String body,
    String kind = 'text',
    int? secretTtl,
  }) async {
    try {
      final res = await client.sendChatMessage(
        chatId,
        topicId: topicId,
        body: body,
        kind: kind,
        secretTtl: secretTtl,
      );
      final sent = ChatMessage.fromJson(res);
      final key = '$chatId:$topicId';
      final current = _messages[key] ?? const [];
      // Новое сообщение вставляется на позицию 0 (самый низ экрана в reverse: true)
      _messages[key] = [sent, ...current];
      notifyListeners();
    } catch (e) {
      DebugLogService.instance.record('chat.send.failed', error: e);
      rethrow;
    }
  }

  Future<void> markRead(ApiClient client, String chatId, int topicId, int lastReadId) async {
    try {
      await client.markChatRead(chatId, topicId, lastReadId);
      // Уменьшаем счетчик в UI локально
      _updateLocalUnread(chatId, topicId);
      notifyListeners();
    } catch (e) {
      DebugLogService.instance.record('chat.mark_read.failed', error: e);
    }
  }

  void _updateLocalUnread(String chatId, int topicId) {
    _chats = _chats.map((c) {
      if (c.id == chatId && c.unreadCount > 0) {
        return ChatItem(
          id: c.id,
          kind: c.kind,
          title: c.title,
          description: c.description,
          avatarUrl: c.avatarUrl,
          isForum: c.isForum,
          isArchived: c.isArchived,
          unreadCount: 0,
          updatedAt: c.updatedAt,
        );
      }
      return c;
    }).toList();
  }

  void onWebSocketEvent(Map<String, dynamic> event) {
    final type = event['type'] as String?;
    if (type == 'chat.message') {
      final payload = event['payload'] as Map<String, dynamic>?;
      final rawMsg = payload?['message'] as Map<String, dynamic>?;
      if (rawMsg != null) {
        final msg = ChatMessage.fromJson(rawMsg);
        final key = '${msg.chatId}:${msg.topicId}';
        final current = _messages[key] ?? const [];
        _messages[key] = [msg, ...current];
        notifyListeners();
      }
    }
  }
}
