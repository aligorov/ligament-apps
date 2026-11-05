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
class ReplyPreview {
  final int id;
  final String senderId;
  final String senderName;
  final String body;

  const ReplyPreview({
    required this.id,
    required this.senderId,
    required this.senderName,
    required this.body,
  });

  factory ReplyPreview.fromJson(Map<String, dynamic> json) {
    return ReplyPreview(
      id: (json['id'] as num?)?.toInt() ?? 0,
      senderId: json['sender_id'] as String? ?? '',
      senderName: json['sender_name'] as String? ?? '',
      body: json['body'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'sender_id': senderId,
    'sender_name': senderName,
    'body': body,
  };
}

class ChatMessage {
  final int id;
  final String chatId;
  final int topicId;
  final String senderId;
  final String senderName;
  final String clientMsgId;
  final int? replyToId;
  final ReplyPreview? replyTo;
  final String body;
  final String kind; // text, secret, action_card, link_call, system
  final int? secretTtlSeconds;
  final DateTime? secretReadAt;
  final Map<String, dynamic> metadata;
  final List<Map<String, dynamic>> rawAttachments;
  final DateTime createdAt;
  final DateTime? editedAt;
  final DateTime? deletedAt;

  List<InlineSpan>? _cachedSpans;

  ChatMessage({
    required this.id,
    required this.chatId,
    this.topicId = 0,
    required this.senderId,
    required this.senderName,
    required this.clientMsgId,
    this.replyToId,
    this.replyTo,
    required this.body,
    this.kind = 'text',
    this.secretTtlSeconds,
    this.secretReadAt,
    this.metadata = const {},
    this.rawAttachments = const [],
    required this.createdAt,
    this.editedAt,
    this.deletedAt,
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
      replyTo: json['reply_to'] is Map<String, dynamic>
          ? ReplyPreview.fromJson(json['reply_to'] as Map<String, dynamic>)
          : null,
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
      editedAt: json['edited_at'] != null
          ? DateTime.tryParse(json['edited_at'] as String)
          : null,
      deletedAt: json['deleted_at'] != null
          ? DateTime.tryParse(json['deleted_at'] as String)
          : null,
    );
  }

  bool get isEdited => editedAt != null;
  bool get isForwarded => metadata.containsKey('forward') && metadata['forward'] is Map;
  String? get forwardSenderName {
    if (!isForwarded) return null;
    final f = metadata['forward'] as Map;
    return f['sender_name'] as String? ?? f['sender_id'] as String?;
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
  final String status;
  final String statusText;

  const ChatContact({
    this.id = '',
    required this.username,
    required this.displayName,
    this.email = '',
    this.title = '',
    this.status = '',
    this.statusText = '',
  });

  String get userId => id;

  factory ChatContact.fromJson(Map<String, dynamic> json) {
    return ChatContact(
      id: json['id'] as String? ?? json['user_id'] as String? ?? '',
      username: json['username'] as String? ?? '',
      displayName: json['display_name'] as String? ?? '',
      email: json['email'] as String? ?? '',
      title: json['title'] as String? ?? json['department'] as String? ?? '',
      status: json['status'] as String? ?? '',
      statusText: json['status_text'] as String? ?? '',
    );
  }
}

@immutable
class UserPresence {
  final String userId;
  final String status; // online, busy, vacation, away, dnd, offline
  final String statusText;
  final bool isOnline;
  final DateTime updatedAt;

  const UserPresence({
    required this.userId,
    this.status = 'offline',
    this.statusText = '',
    this.isOnline = false,
    required this.updatedAt,
  });

  factory UserPresence.fromJson(Map<String, dynamic> json) {
    return UserPresence(
      userId: json['user_id'] as String? ?? '',
      status: json['status'] as String? ?? (json['is_online'] == true ? 'online' : 'offline'),
      statusText: json['status_text'] as String? ?? '',
      isOnline: json['is_online'] as bool? ?? false,
      updatedAt: json['updated_at'] != null
          ? DateTime.tryParse(json['updated_at'] as String) ?? DateTime.now()
          : DateTime.now(),
    );
  }

  /// Читаемое название статуса
  String get statusLabel {
    switch (status) {
      case 'busy':
        return 'Занят';
      case 'vacation':
        return 'В отпуске';
      case 'away':
        return 'Отошёл';
      case 'dnd':
        return 'Не беспокоить';
      case 'online':
        return isOnline ? 'В сети' : 'Не в сети';
      default:
        return isOnline ? 'В сети' : 'Не в сети';
    }
  }

  /// Эмодзи статуса
  String get statusEmoji {
    switch (status) {
      case 'busy':
        return '🔴';
      case 'vacation':
        return '🌴';
      case 'away':
        return '🟡';
      case 'dnd':
        return '⛔';
      case 'online':
        return isOnline ? '🟢' : '⚫';
      default:
        return isOnline ? '🟢' : '⚫';
    }
  }

  /// Семантический цвет индикатора
  Color get statusColor {
    switch (status) {
      case 'busy':
      case 'dnd':
        return const Color(0xFFEF4444);
      case 'vacation':
        return const Color(0xFF06B6D4);
      case 'away':
        return const Color(0xFFF59E0B);
      case 'online':
        return isOnline ? const Color(0xFF10B981) : const Color(0xFF94A3B8);
      default:
        return isOnline ? const Color(0xFF10B981) : const Color(0xFF94A3B8);
    }
  }

  bool get isBusyOrDnd => status == 'busy' || status == 'dnd';

  String get fullStatusDisplay {
    if (!isOnline && (status == 'online' || status == 'offline')) {
      return statusLabel;
    }
    final prefix = (status == 'online' || status == 'offline') ? '' : '$statusEmoji ';
    if (statusText.trim().isNotEmpty) {
      return '$prefix$statusLabel (${statusText.trim()})';
    }
    return '$prefix$statusLabel';
  }
}
