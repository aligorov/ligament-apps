import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../api/client.dart';
import '../models/chat_models.dart';
import 'alert_service.dart';
import 'call_session_manager.dart';
import 'debug_log_service.dart';

class ChatService extends ChangeNotifier {
  static final ChatService instance = ChatService._();
  ChatService._() {
    unawaited(initSettings());
  }

  List<ChatItem> _chats = const [];
  List<ChatContact> _contacts = const [];
  final Map<String, List<TopicItem>> _topics = {};
  final Map<String, List<ChatMessage>> _messages = {}; // key: "$chatId:$topicId"
  final Map<String, UserPresence> _presences = {};
  bool _isLoadingChats = false;
  final Set<String> _loadingMessages = {};
  bool _playSounds = true;
  bool _showNotifications = true;

  bool get playSounds => _playSounds;
  bool get showNotifications => _showNotifications;

  List<ChatItem> get chats => _chats;
  List<ChatContact> get contacts => _contacts;
  Map<String, UserPresence> get presences => _presences;
  bool get isLoadingChats => _isLoadingChats;

  UserPresence getPresence(String userId) {
    return _presences[userId] ??
        UserPresence(
          userId: userId,
          status: 'offline',
          isOnline: false,
          updatedAt: DateTime.now(),
        );
  }

  Future<void> loadPresences(ApiClient client) async {
    try {
      final list = await client.getChatPresences();
      for (final raw in list) {
        final p = UserPresence.fromJson(raw);
        _presences[p.userId] = p;
      }
      notifyListeners();
    } catch (e) {
      DebugLogService.instance.record('chat.presences.failed', error: e);
    }
  }

  Future<void> setMyStatus(ApiClient client, String status, {String statusText = ''}) async {
    try {
      sendWs({
        'type': 'presence.set',
        'payload': {
          'status': status,
          'status_text': statusText,
        },
      });
      final res = await client.setChatPresence(status: status, statusText: statusText);
      final p = UserPresence.fromJson(res);
      _presences[p.userId] = p;
      notifyListeners();
    } catch (e) {
      DebugLogService.instance.record('chat.presence_set.failed', error: e);
      rethrow;
    }
  }

  int get totalUnreadCount {
    var count = 0;
    for (final c in _chats) {
      count += c.unreadCount;
    }
    return count;
  }

  String? _activeChatId;
  int _activeTopicId = 0;
  String? _currentUsername;
  bool _isForeground = true;

  String? get activeChatId => _activeChatId;
  bool get isForeground => _isForeground;

  void setCurrentUser(String username) {
    _currentUsername = username.trim();
  }

  void joinChatRoom(String chatId) {
    if (chatId.isEmpty || _wsChannel == null || !_isWsConnected) return;
    sendWs({'type': 'room.join', 'chat_id': chatId});
  }

  void leaveChatRoom(String chatId) {
    if (chatId.isEmpty || _wsChannel == null || !_isWsConnected) return;
    sendWs({'type': 'room.leave', 'chat_id': chatId});
  }

  void setForegroundState(bool isForeground) {
    if (_isForeground == isForeground) return;
    _isForeground = isForeground;
    final activeId = _activeChatId;
    if (activeId == null) return;
    if (isForeground) {
      joinChatRoom(activeId);
    } else {
      leaveChatRoom(activeId);
    }
  }

  void setActiveChat(String? chatId, [int? topicId]) {
    final prevChatId = _activeChatId;
    if (prevChatId != null && prevChatId != chatId) {
      leaveChatRoom(prevChatId);
    }
    _activeChatId = chatId;
    _activeTopicId = topicId ?? 0;
    if (chatId != null) {
      _updateLocalUnread(chatId, _activeTopicId);
      if (_isForeground) {
        joinChatRoom(chatId);
      }
    }
    notifyListeners();
  }

  List<TopicItem> getTopics(String chatId) => _topics[chatId] ?? const [];
  List<ChatMessage> getMessages(String chatId, int topicId) {
    final list = _messages['$chatId:$topicId'];
    if (list == null || list.isEmpty) return const [];
    var hasDupes = false;
    final seen = <int>{};
    for (final m in list) {
      if (m.id > 0 && !seen.add(m.id)) {
        hasDupes = true;
        break;
      }
    }
    if (!hasDupes) return list;
    final clean = <ChatMessage>[];
    final cleanSeen = <int>{};
    for (final m in list) {
      if (m.id > 0 && !cleanSeen.add(m.id)) continue;
      clean.add(m);
    }
    _messages['$chatId:$topicId'] = clean;
    return clean;
  }

  /// Фильтрует список диалогов по поисковому запросу и категории.
  static List<ChatItem> filterChatList(
    List<ChatItem> source, {
    String query = '',
    String category = 'all',
  }) {
    final cleanQuery = query.trim().toLowerCase();
    return source.where((c) {
      if (category == 'direct' && c.kind != 'direct') return false;
      if (category == 'forum' && !c.isForum) return false;
      if (category == 'unread' && c.unreadCount <= 0) return false;

      if (cleanQuery.isNotEmpty) {
        final matchesTitle = c.title.toLowerCase().contains(cleanQuery);
        final matchesPeer = c.peerUserId.toLowerCase().contains(cleanQuery);
        final matchesDesc = c.description.toLowerCase().contains(cleanQuery);
        if (!matchesTitle && !matchesPeer && !matchesDesc) return false;
      }
      return true;
    }).toList();
  }

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

  void _sortTopics(String chatId) {
    final list = _topics[chatId];
    if (list == null || list.isEmpty) return;
    list.sort((a, b) {
      if (a.isPinned != b.isPinned) return b.isPinned ? 1 : -1;
      if (a.isGeneral != b.isGeneral) return b.isGeneral ? 1 : -1;
      return a.id.compareTo(b.id);
    });
  }

  Future<List<TopicItem>> loadTopics(ApiClient client, String chatId) async {
    try {
      final list = await client.getChatTopics(chatId);
      final topics = list.map(TopicItem.fromJson).toList();
      _topics[chatId] = topics;
      _sortTopics(chatId);
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

  Future<ChatItem> createDirectChat(ApiClient client, String targetUser, {String targetName = ''}) async {
    final res = await client.createChat(
      kind: 'direct',
      targetUser: targetUser,
      targetName: targetName.isNotEmpty ? targetName : null,
    );
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
        final existingIds = current.map((m) => m.id).where((id) => id > 0).toSet();
        final filteredBatch = reversedBatch.where((m) => !existingIds.contains(m.id)).toList();
        _messages[key] = [...current, ...filteredBatch];
      } else {
        final seen = <int>{};
        final deduped = <ChatMessage>[];
        for (final m in reversedBatch) {
          if (m.id > 0 && !seen.add(m.id)) continue;
          deduped.add(m);
        }
        _messages[key] = deduped;
      }

      if (fetched.isNotEmpty) {
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
    int? replyToId,
    int? forwardMessageId,
    int? secretTtl,
    Map<String, dynamic>? metadata,
    List<String>? attachments,
    String? clientMsgId,
  }) async {
    final cMsgId = (clientMsgId != null && clientMsgId.isNotEmpty)
        ? clientMsgId
        : 'cmsg_${DateTime.now().microsecondsSinceEpoch}';
    try {
      final res = await client.sendChatMessage(
        chatId,
        topicId: topicId,
        body: body,
        kind: kind,
        replyToId: replyToId,
        forwardMessageId: forwardMessageId,
        secretTtl: secretTtl,
        metadata: metadata,
        attachments: attachments,
        clientMsgId: cMsgId,
      );
      final sent = ChatMessage.fromJson(res);
      final key = '$chatId:$topicId';
      final current = _messages[key] ?? const [];
      // Если сообщение уже доставлено через WebSocket (echo), не дублируем его в списке
      if (sent.id > 0 && current.any((m) => m.id == sent.id)) {
        return;
      }
      if (sent.clientMsgId.isNotEmpty &&
          current.any((m) => m.clientMsgId.isNotEmpty && m.clientMsgId == sent.clientMsgId)) {
        return;
      }
      // Новое сообщение вставляется на позицию 0 (самый низ экрана в reverse: true)
      _messages[key] = [sent, ...current];
      notifyListeners();
    } catch (e) {
      DebugLogService.instance.record('chat.send.failed', error: e);
      rethrow;
    }
  }

  /// Удаление сообщения из чата (у всех или только у себя)
  Future<void> deleteMessage(
    ApiClient client,
    String chatId,
    int messageId, {
    int topicId = 0,
    bool forEveryone = false,
  }) async {
    try {
      await client.deleteChatMessage(chatId, messageId, forEveryone: forEveryone);
      final key = '$chatId:$topicId';
      final current = _messages[key];
      if (current != null) {
        _messages[key] = current.where((m) => m.id != messageId).toList();
        notifyListeners();
      }
    } catch (e) {
      DebugLogService.instance.record('chat.delete.failed', error: e);
      rethrow;
    }
  }

  /// Редактирование текста сообщения
  Future<void> editMessage(
    ApiClient client,
    String chatId,
    int messageId, {
    int topicId = 0,
    required String body,
  }) async {
    try {
      final res = await client.editChatMessage(chatId, messageId, body: body);
      final updated = ChatMessage.fromJson(res);
      final key = '$chatId:$topicId';
      final current = _messages[key];
      if (current != null) {
        _messages[key] = current.map((m) => m.id == messageId ? updated : m).toList();
        notifyListeners();
      }
    } catch (e) {
      DebugLogService.instance.record('chat.edit.failed', error: e);
      rethrow;
    }
  }

  /// Пересылка сообщения в другой чат / топик
  Future<void> forwardMessage(
    ApiClient client,
    String targetChatId, {
    int targetTopicId = 0,
    required ChatMessage originalMessage,
  }) async {
    final cMsgId = 'fwd_${DateTime.now().microsecondsSinceEpoch}';
    try {
      final res = await client.sendChatMessage(
        targetChatId,
        topicId: targetTopicId,
        body: originalMessage.body,
        kind: originalMessage.kind,
        forwardMessageId: originalMessage.id,
        clientMsgId: cMsgId,
      );
      final sent = ChatMessage.fromJson(res);
      final key = '$targetChatId:$targetTopicId';
      final current = _messages[key] ?? const [];
      if (sent.id > 0 && current.any((m) => m.id == sent.id)) {
        return;
      }
      if (sent.clientMsgId.isNotEmpty &&
          current.any((m) => m.clientMsgId.isNotEmpty && m.clientMsgId == sent.clientMsgId)) {
        return;
      }
      _messages[key] = [sent, ...current];
      notifyListeners();
    } catch (e) {
      DebugLogService.instance.record('chat.forward.failed', error: e);
      rethrow;
    }
  }

  Future<String> sendAttachment(
    ApiClient client,
    String chatId, {
    int topicId = 0,
    required String fileName,
    required List<int> bytes,
  }) async {
    try {
      final att = await client.uploadChatAttachment(chatId, bytes, fileName);
      final attId = att['id'] as String? ?? '';
      final lowerName = fileName.toLowerCase();
      final isImage = lowerName.endsWith('.png') ||
          lowerName.endsWith('.jpg') ||
          lowerName.endsWith('.jpeg') ||
          lowerName.endsWith('.gif') ||
          lowerName.endsWith('.webp');
      final isVideo = lowerName.endsWith('.mp4') ||
          lowerName.endsWith('.mov') ||
          lowerName.endsWith('.webm') ||
          lowerName.endsWith('.mkv') ||
          lowerName.endsWith('.avi') ||
          lowerName.endsWith('.m4v');

      final kind = isImage ? 'image' : (isVideo ? 'video' : 'file');
      final body = isImage ? '📷 $fileName' : (isVideo ? '🎥 $fileName' : '📎 $fileName');

      await sendMessage(
        client,
        chatId,
        topicId: topicId,
        body: body,
        kind: kind,
        attachments: attId.isNotEmpty ? [attId] : null,
        metadata: {
          'attachments': [
            {
              'id': attId,
              'name': fileName,
              'size': bytes.length,
              'content_type': att['content_type'] ?? (isVideo ? 'video/mp4' : 'application/octet-stream'),
            }
          ]
        },
      );
      return attId;
    } catch (e) {
      DebugLogService.instance.record('chat.attachment.failed', error: e);
      rethrow;
    }
  }

  /// Создание новой темы форума
  Future<TopicItem> createTopic(
    ApiClient client,
    String chatId, {
    required String title,
    String iconEmoji = '💬',
  }) async {
    try {
      final res = await client.createChatTopic(chatId, title: title, iconEmoji: iconEmoji);
      final newTopic = TopicItem.fromJson(res);
      final current = _topics[chatId] ?? const [];
      _topics[chatId] = [...current, newTopic];
      _sortTopics(chatId);
      notifyListeners();
      return newTopic;
    } catch (e) {
      DebugLogService.instance.record('chat.topic_create.failed', error: e);
      rethrow;
    }
  }

  /// Обновление параметров темы форума
  Future<TopicItem> updateTopic(
    ApiClient client,
    String chatId,
    int topicId, {
    String? title,
    String? iconEmoji,
    bool? isPinned,
    bool? isClosed,
  }) async {
    try {
      final res = await client.updateChatTopic(
        chatId,
        topicId,
        title: title,
        iconEmoji: iconEmoji,
        isPinned: isPinned,
        isClosed: isClosed,
      );
      final updated = TopicItem.fromJson(res);
      final current = _topics[chatId];
      if (current != null) {
        _topics[chatId] = current.map((t) => t.id == updated.id ? updated : t).toList();
        _sortTopics(chatId);
        notifyListeners();
      }
      return updated;
    } catch (e) {
      DebugLogService.instance.record('chat.topic_update.failed', error: e);
      rethrow;
    }
  }

  /// Удаление темы форума
  Future<void> deleteTopic(
    ApiClient client,
    String chatId,
    int topicId,
  ) async {
    try {
      await client.deleteChatTopic(chatId, topicId);
      final current = _topics[chatId];
      if (current != null) {
        _topics[chatId] = current.where((t) => t.id != topicId).toList();
        _messages.remove('$chatId:$topicId');
        notifyListeners();
      }
    } catch (e) {
      DebugLogService.instance.record('chat.topic_delete.failed', error: e);
      rethrow;
    }
  }

  void markLocalRead(String chatId) {
    _updateLocalUnread(chatId, 0);
    notifyListeners();
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

  Future<void> initSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _playSounds = prefs.getBool('chat_sound_enabled') ?? true;
      _showNotifications = prefs.getBool('chat_notifications_enabled') ?? true;
      notifyListeners();
    } catch (_) {}
  }

  Future<void> setPlaySounds(bool val) async {
    _playSounds = val;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('chat_sound_enabled', val);
    } catch (_) {}
  }

  Future<void> setShowNotifications(bool val) async {
    _showNotifications = val;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('chat_notifications_enabled', val);
    } catch (_) {}
  }

  Future<void> deleteChat(ApiClient client, String chatId) async {
    try {
      await client.deleteChat(chatId);
      _chats = _chats.where((c) => c.id != chatId).toList();
      _messages.removeWhere((k, _) => k.startsWith('$chatId:'));
      notifyListeners();
    } catch (e) {
      DebugLogService.instance.record('chat.delete.failed', error: e, fields: {'chat_id': chatId});
      rethrow;
    }
  }

  WebSocketChannel? _wsChannel;
  bool _isWsConnected = false;
  bool _isWsConnecting = false;
  Timer? _reconnectTimer;
  ApiClient? _lastClient;
  final List<String> _pendingOutgoingWs = [];

  bool get isWsConnected => _isWsConnected;

  void connectWebSocket(ApiClient client, {bool force = false}) {
    CallSessionManager.instance.onSendSignal = (targetUserId, chatId, payload) {
      sendWebRTCSignal(targetUserId, chatId, payload);
    };
    CallSessionManager.instance.onToggleRecording = (callId, {required record, bool isVideo = false}) {
      return client.toggleCallRecording(callId, record: record, isVideo: isVideo);
    };
    CallSessionManager.instance.onSendRecordOffer = (callId, {required sdp, String? participantId}) {
      return client.sendCallRecordOffer(callId, sdp: sdp, participantId: participantId);
    };

    if (!force &&
        (_isWsConnected || _isWsConnecting) &&
        _lastClient?.token == client.token &&
        _lastClient?.baseUrl == client.baseUrl) {
      return;
    }
    _lastClient = client;

    unawaited(loadPresences(client));
    _connectWsInternal();
  }

  void ensureConnected([ApiClient? client]) {
    if (client != null) {
      _lastClient = client;
    }
    if (!_isWsConnected && !_isWsConnecting && _lastClient != null) {
      _connectWsInternal();
    }
  }

  void _connectWsInternal() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;

    final client = _lastClient;
    if (client == null || client.baseUrl.isEmpty) return;

    final wsBase = client.baseUrl
        .replaceFirst('http://', 'ws://')
        .replaceFirst('https://', 'wss://');
    final token = client.token ?? '';
    final urlStr = '$wsBase/apps/chat/api/v1/ws?token=${Uri.encodeComponent(token)}';

    try {
      final uri = Uri.parse(urlStr);
      final headers = <String, String>{
        if (token.isNotEmpty) 'Authorization': 'Bearer $token',
      };

      _isWsConnecting = true;
      _wsChannel?.sink.close();
      final ch = IOWebSocketChannel.connect(
        uri,
        headers: headers,
        pingInterval: const Duration(seconds: 15),
      );
      _wsChannel = ch;

      unawaited(ch.ready.then((_) {
        if (!identical(_wsChannel, ch)) return;
        _isWsConnecting = false;
        _isWsConnected = true;
        _flushPendingOutgoingWs();
        if (_activeChatId != null && _isForeground) {
          joinChatRoom(_activeChatId!);
          if (_lastClient != null) {
            unawaited(loadMessages(_lastClient!, _activeChatId!, topicId: _activeTopicId));
          }
        }
        notifyListeners();
      }).catchError((e) {
        if (!identical(_wsChannel, ch)) return;
        _isWsConnecting = false;
        _isWsConnected = false;
        notifyListeners();
        _scheduleReconnect();
      }));

      ch.stream.listen(
        (data) {
          try {
            final str = data is List<int> ? utf8.decode(data) : data.toString();
            final lines = str.split('\n');
            for (final line in lines) {
              final trimmed = line.trim();
              if (trimmed.isEmpty) continue;
              final map = jsonDecode(trimmed) as Map<String, dynamic>;
              onWebSocketEvent(map);
            }
          } catch (e) {
            DebugLogService.instance.record('chat.ws.parse.failed', error: e);
          }
        },
        onError: (e) {
          if (!identical(_wsChannel, ch)) return;
          _isWsConnecting = false;
          _isWsConnected = false;
          notifyListeners();
          _scheduleReconnect();
        },
        onDone: () {
          if (!identical(_wsChannel, ch)) return;
          _isWsConnecting = false;
          _isWsConnected = false;
          notifyListeners();
          _scheduleReconnect();
        },
        cancelOnError: true,
      );
    } catch (e) {
      _isWsConnecting = false;
      _isWsConnected = false;
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 3), () {
      _connectWsInternal();
    });
  }

  void disconnectWebSocket() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _wsChannel?.sink.close();
    _wsChannel = null;
    _isWsConnecting = false;
    _isWsConnected = false;
    _activeChatId = null;
    _activeTopicId = 0;
    _currentUsername = null;
    _isForeground = true;
    _pendingOutgoingWs.clear();
    notifyListeners();
  }

  void _flushPendingOutgoingWs() {
    if (_wsChannel == null || !_isWsConnected || _pendingOutgoingWs.isEmpty) return;
    final items = List<String>.from(_pendingOutgoingWs);
    _pendingOutgoingWs.clear();
    for (final raw in items) {
      try {
        _wsChannel!.sink.add(raw);
      } catch (e) {
        DebugLogService.instance.record('chat.ws.flush.failed', error: e);
      }
    }
  }

  void sendWs(Map<String, dynamic> data) {
    final encoded = jsonEncode(data);
    if (_wsChannel != null && _isWsConnected) {
      try {
        _wsChannel!.sink.add(encoded);
        return;
      } catch (e) {
        DebugLogService.instance.record('chat.ws.send.failed', error: e);
        _isWsConnected = false;
      }
    }
    if (_pendingOutgoingWs.length >= 64) {
      _pendingOutgoingWs.removeAt(0);
    }
    _pendingOutgoingWs.add(encoded);
    ensureConnected();
  }

  void sendWebRTCSignal(String targetUserId, String chatId, Map<String, dynamic> payload) {
    sendWs({
      'type': 'webrtc.signal',
      'chat_id': chatId,
      'target_id': targetUserId,
      'payload': payload,
    });
  }

  void onWebSocketEvent(Map<String, dynamic> event) {
    final type = event['type'] as String?;
    if (type == 'presence.snapshot') {
      final payload = event['payload'] as Map<String, dynamic>?;
      final rawList = payload?['presences'] as List<dynamic>?;
      if (rawList != null) {
        for (final raw in rawList) {
          if (raw is Map<String, dynamic>) {
            final p = UserPresence.fromJson(raw);
            _presences[p.userId] = p;
          }
        }
        notifyListeners();
      }
    } else if (type == 'presence.update') {
      final payload = event['payload'] as Map<String, dynamic>?;
      final rawPresence = payload?['presence'] as Map<String, dynamic>?;
      if (rawPresence != null) {
        final p = UserPresence.fromJson(rawPresence);
        _presences[p.userId] = p;
        notifyListeners();
      }
    } else if (type == 'chat.message') {
      final payload = event['payload'] as Map<String, dynamic>?;
      final rawMsg = payload?['message'] as Map<String, dynamic>?;
      if (rawMsg != null) {
        final msg = ChatMessage.fromJson(rawMsg);
        final key = '${msg.chatId}:${msg.topicId}';
        final current = _messages[key] ?? const [];
        if (msg.id > 0 && current.any((m) => m.id == msg.id)) {
          return;
        }
        if (msg.clientMsgId.isNotEmpty &&
            current.any((m) => m.clientMsgId.isNotEmpty && m.clientMsgId == msg.clientMsgId)) {
          return;
        }
        _messages[key] = [msg, ...current];

        final isMe = _currentUsername != null &&
            _currentUsername!.isNotEmpty &&
            msg.senderId.toLowerCase() == _currentUsername!.toLowerCase();
        final isViewingThisChat = _activeChatId == msg.chatId && _isForeground;

        if (!isViewingThisChat) {
          final hasChat = _chats.any((c) => c.id == msg.chatId);
          if (hasChat) {
            _chats = _chats.map((c) {
              if (c.id == msg.chatId) {
                return ChatItem(
                  id: c.id,
                  kind: c.kind,
                  title: c.title,
                  description: c.description,
                  avatarUrl: c.avatarUrl,
                  isForum: c.isForum,
                  isArchived: c.isArchived,
                  unreadCount: isMe ? c.unreadCount : c.unreadCount + 1,
                  updatedAt: msg.createdAt,
                  peerUserId: c.peerUserId,
                  myRole: c.myRole,
                );
              }
              return c;
            }).toList();
          } else if (_lastClient != null) {
            unawaited(loadChats(_lastClient!));
          }

          if (!isMe && _showNotifications) {
            final sender = msg.senderName.isNotEmpty ? msg.senderName : msg.senderId;
            final body = msg.body.isNotEmpty ? msg.body : 'Новое сообщение';
            unawaited(
              AlertService.instance.triggerChatUnreadNotification(
                title: sender.isNotEmpty ? sender : 'Ligament Chat',
                body: body,
                chatId: msg.chatId,
              ),
            );
          }
        }
        if (_playSounds && !isMe) {
          SystemSound.play(SystemSoundType.alert);
        }
        notifyListeners();
      }
    } else if (type == 'chat.message_deleted') {
      final chatId = event['chat_id'] as String? ?? '';
      final topicId = (event['topic_id'] as num?)?.toInt() ?? 0;
      final payload = event['payload'] as Map<String, dynamic>? ?? {};
      final msgId = (payload['message_id'] as num?)?.toInt();
      if (msgId != null) {
        final key = '$chatId:$topicId';
        final current = _messages[key];
        if (current != null) {
          _messages[key] = current.where((m) => m.id != msgId).toList();
          notifyListeners();
        }
      }
    } else if (type == 'chat.message_updated') {
      final chatId = event['chat_id'] as String? ?? '';
      final topicId = (event['topic_id'] as num?)?.toInt() ?? 0;
      final payload = event['payload'] as Map<String, dynamic>? ?? {};
      final rawMsg = payload['message'] as Map<String, dynamic>?;
      if (rawMsg != null) {
        final updated = ChatMessage.fromJson(rawMsg);
        final key = '$chatId:$topicId';
        final current = _messages[key];
        if (current != null) {
          _messages[key] = current.map((m) => m.id == updated.id ? updated : m).toList();
          notifyListeners();
        }
      }
    } else if (type == 'chat.topic_created') {
      final chatId = event['chat_id'] as String? ?? '';
      final payload = event['payload'] as Map<String, dynamic>? ?? {};
      final rawTopic = payload['topic'] as Map<String, dynamic>?;
      if (chatId.isNotEmpty && rawTopic != null) {
        final newTopic = TopicItem.fromJson(rawTopic);
        final current = _topics[chatId] ?? const [];
        if (!current.any((t) => t.id == newTopic.id)) {
          _topics[chatId] = [...current, newTopic];
          _sortTopics(chatId);
          notifyListeners();
        }
      }
    } else if (type == 'chat.topic_updated') {
      final chatId = event['chat_id'] as String? ?? '';
      final payload = event['payload'] as Map<String, dynamic>? ?? {};
      final rawTopic = payload['topic'] as Map<String, dynamic>?;
      if (chatId.isNotEmpty && rawTopic != null) {
        final updated = TopicItem.fromJson(rawTopic);
        final current = _topics[chatId];
        if (current != null) {
          _topics[chatId] = current.map((t) => t.id == updated.id ? updated : t).toList();
          _sortTopics(chatId);
          notifyListeners();
        }
      }
    } else if (type == 'chat.topic_deleted') {
      final chatId = event['chat_id'] as String? ?? '';
      final payload = event['payload'] as Map<String, dynamic>? ?? {};
      final deletedId = (payload['topic_id'] as num?)?.toInt() ?? (event['topic_id'] as num?)?.toInt();
      if (chatId.isNotEmpty && deletedId != null) {
        final current = _topics[chatId];
        if (current != null) {
          _topics[chatId] = current.where((t) => t.id != deletedId).toList();
          _messages.remove('$chatId:$deletedId');
          notifyListeners();
        }
      }
    } else if (type == 'webrtc.signal') {
      final targetId = event['target_id'] as String? ?? '';
      final chatId = event['chat_id'] as String? ?? '';
      final payload = event['payload'] as Map<String, dynamic>? ?? {};
      final signalType = payload['type'] as String?;

      if (signalType == 'offer') {
        CallSessionManager.instance.handleIncomingOffer(
          fromUser: targetId,
          chatId: chatId,
          offerPayload: payload,
        );
      } else if (signalType == 'ringing') {
        CallSessionManager.instance.handleRinging();
      } else if (signalType == 'offline') {
        CallSessionManager.instance.handleOffline();
      } else if (signalType == 'busy') {
        CallSessionManager.instance.handleBusy();
      } else if (signalType == 'answer') {
        final sdp = payload['sdp'] as String? ?? '';
        if (sdp.isNotEmpty) {
          unawaited(CallSessionManager.instance.handleAnswer(sdp));
        }
      } else if (signalType == 'candidate') {
        final cand = payload['candidate'] as Map<String, dynamic>? ?? {};
        unawaited(CallSessionManager.instance.handleRemoteCandidate(cand));
      } else if (signalType == 'candidates') {
        final cands = payload['candidates'] as List<dynamic>? ?? [];
        for (final c in cands) {
          if (c is Map<String, dynamic>) {
            unawaited(CallSessionManager.instance.handleRemoteCandidate(c));
          } else if (c is Map) {
            unawaited(CallSessionManager.instance.handleRemoteCandidate(Map<String, dynamic>.from(c)));
          }
        }
      } else if (signalType == 'cancel') {
        final reason = payload['reason'] as String? ?? '';
        CallSessionManager.instance.handleCancel(reason: reason);
      } else if (signalType == 'hangup' || signalType == 'rejected') {
        CallSessionManager.instance.endCall(notifyPeer: false);
      }
    } else if (type == 'call.recording') {
      final payload = event['payload'] as Map<String, dynamic>? ?? {};
      final isRecorded = payload['is_recorded'] == true;
      final recId = payload['recorder_session_id'] as String?;
      CallSessionManager.instance.handleRecordingState(
        isRecorded: isRecorded,
        recorderSessionId: recId,
      );
    }
  }

  @visibleForTesting
  void setChatsForTest(List<ChatItem> chats) {
    _chats = chats;
    notifyListeners();
  }

  @visibleForTesting
  void setMessagesForTest(String chatId, int topicId, List<ChatMessage> messages) {
    _messages['$chatId:$topicId'] = messages;
    notifyListeners();
  }

  @visibleForTesting
  void resetForTest() {
    disconnectWebSocket();
    _chats = const [];
    _messages.clear();
    _topics.clear();
    notifyListeners();
  }
}
