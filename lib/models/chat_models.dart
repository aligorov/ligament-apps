import 'package:flutter/widgets.dart';
import '../screens/chat/chat_format_tokenizer.dart';

@immutable
class ChatItem {
  final String id;
  final String kind; // direct, group, forum, channel, saved
  final String title;
  final String description;
  final String avatarUrl;
  final bool isForum;
  final bool isArchived;
  final int unreadCount;
  final DateTime updatedAt;
  final String peerUserId;

  const ChatItem({
    required this.id,
    required this.kind,
    required this.title,
    this.description = '',
    this.avatarUrl = '',
    this.isForum = false,
    this.isArchived = false,
    this.unreadCount = 0,
    required this.updatedAt,
    this.peerUserId = '',
  });

  factory ChatItem.fromJson(Map<String, dynamic> json) {
    return ChatItem(
      id: json['id'] as String? ?? '',
      kind: json['kind'] as String? ?? 'group',
      title: json['title'] as String? ?? '',
      description: json['description'] as String? ?? '',
      avatarUrl: json['avatar_url'] as String? ?? '',
      isForum: json['is_forum'] as bool? ?? false,
      isArchived: json['is_archived'] as bool? ?? false,
      unreadCount: (json['unread_count'] as num?)?.toInt() ?? 0,
      updatedAt: json['updated_at'] != null
          ? DateTime.tryParse(json['updated_at'] as String) ?? DateTime.now()
          : DateTime.now(),
      peerUserId: json['peer_user_id'] as String? ?? '',
    );
  }
}

@immutable
class TopicItem {
  final int id;
  final String chatId;
  final String title;
  final String iconEmoji;
  final bool isGeneral;
  final bool isClosed;
  final bool isPinned;
  final int unreadCount;

  const TopicItem({
    required this.id,
    required this.chatId,
    required this.title,
    this.iconEmoji = '💬',
    this.isGeneral = false,
    this.isClosed = false,
    this.isPinned = false,
    this.unreadCount = 0,
  });

  factory TopicItem.fromJson(Map<String, dynamic> json) {
    return TopicItem(
      id: (json['id'] as num?)?.toInt() ?? 0,
      chatId: json['chat_id'] as String? ?? '',
      title: json['title'] as String? ?? '',
      iconEmoji: json['icon_emoji'] as String? ?? '💬',
      isGeneral: json['is_general'] as bool? ?? false,
      isClosed: json['is_closed'] as bool? ?? false,
      isPinned: json['is_pinned'] as bool? ?? false,
      unreadCount: (json['unread_count'] as num?)?.toInt() ?? 0,
    );
  }
}

// ignore: must_be_immutable
class ChatMessage {
  final int id;
  final String chatId;
  final int topicId;
  final String senderId;
  final String senderName;
  final String clientMsgId;
  final int? replyToId;
  final String body;
  final String kind; // text, secret, action_card, link_call, system
  final int? secretTtlSeconds;
  final DateTime? secretReadAt;
  final Map<String, dynamic> metadata;
  final List<Map<String, dynamic>> rawAttachments;
  final DateTime createdAt;

  List<InlineSpan>? _cachedSpans;

  ChatMessage({
    required this.id,
    required this.chatId,
    this.topicId = 0,
    required this.senderId,
    required this.senderName,
    required this.clientMsgId,
    this.replyToId,
    required this.body,
    this.kind = 'text',
    this.secretTtlSeconds,
    this.secretReadAt,
    this.metadata = const {},
    this.rawAttachments = const [],
    required this.createdAt,
  });

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    var rawAtts = const <Map<String, dynamic>>[];
    if (json['attachments'] is List) {
      rawAtts = (json['attachments'] as List).whereType<Map<String, dynamic>>().toList();
    }
    return ChatMessage(
      id: (json['id'] as num?)?.toInt() ?? 0,
      chatId: json['chat_id'] as String? ?? '',
      topicId: (json['topic_id'] as num?)?.toInt() ?? 0,
      senderId: json['sender_username'] as String? ?? json['sender_id'] as String? ?? '',
      senderName: json['sender_name'] as String? ?? '',
      clientMsgId: json['client_msg_id'] as String? ?? '',
      replyToId: (json['reply_to_id'] as num?)?.toInt(),
      body: json['body'] as String? ?? '',
      kind: json['kind'] as String? ?? 'text',
      secretTtlSeconds: (json['secret_ttl_seconds'] as num?)?.toInt(),
      secretReadAt: json['secret_read_at'] != null
          ? DateTime.tryParse(json['secret_read_at'] as String)
          : null,
      metadata: json['metadata'] as Map<String, dynamic>? ?? const {},
      rawAttachments: rawAtts,
      createdAt: json['created_at'] != null
          ? DateTime.tryParse(json['created_at'] as String) ?? DateTime.now()
          : DateTime.now(),
    );
  }

  bool get hasAttachments => attachments.isNotEmpty;

  List<Map<String, dynamic>> get attachments {
    if (rawAttachments.isNotEmpty) return rawAttachments;
    if (metadata.containsKey('attachments') &&
        metadata['attachments'] is List &&
        (metadata['attachments'] as List).isNotEmpty) {
      return (metadata['attachments'] as List)
          .whereType<Map<String, dynamic>>()
          .toList();
    }
    return const [];
  }

  /// Возвращает кэшированный список сущностей форматирования (жирный, курсив, код, ссылки).
  List<InlineSpan> getSpans(BuildContext context, {void Function(String url)? onLinkTap}) {
    if (_cachedSpans != null) return _cachedSpans!;
    _cachedSpans = ChatFormatTokenizer.tokenize(body, context, onLinkTap: onLinkTap);
    return _cachedSpans!;
  }
}

@immutable
class ChatContact {
  final String id;
  final String username;
  final String displayName;
  final String email;
  final String title;

  const ChatContact({
    this.id = '',
    required this.username,
    required this.displayName,
    this.email = '',
    this.title = '',
  });

  factory ChatContact.fromJson(Map<String, dynamic> json) {
    return ChatContact(
      id: json['id'] as String? ?? '',
      username: json['username'] as String? ?? '',
      displayName: json['display_name'] as String? ?? '',
      email: json['email'] as String? ?? '',
      title: json['title'] as String? ?? '',
    );
  }
}
