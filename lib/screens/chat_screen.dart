import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:provider/provider.dart';
import '../models/chat_models.dart';
import '../services/auth_state.dart';
import '../services/chat_service.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final ChatService _chatService = ChatService.instance;

  ChatItem? _selectedChat;
  TopicItem? _selectedTopic;
  bool _showScrollToBottom = false;
  bool _showEmojiBar = false;
  bool _isUploading = false;

  static const List<String> _quickEmojis = [
    '👍', '❤️', '🔥', '😂', '😊', '🎉', '🚀', '✅', '❌', '👋', '🤔', '🤝', '👏', '💯', '☕'
  ];

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final auth = context.read<AuthState>();
      if (auth.api != null) {
        _chatService.loadContacts(auth.api!);
        _chatService.loadChats(auth.api!).then((_) {
          if (mounted && _selectedChat == null && _chatService.chats.isNotEmpty) {
            final isWide = MediaQuery.of(context).size.width >= 720;
            if (isWide) {
              _selectChat(_chatService.chats.first);
            }
          }
        });
      }
    });
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _textController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.hasClients) {
      final offset = _scrollController.offset;
      if (offset > 250 && !_showScrollToBottom) {
        setState(() => _showScrollToBottom = true);
      } else if (offset <= 250 && _showScrollToBottom) {
        setState(() => _showScrollToBottom = false);
      }

      if (offset >= _scrollController.position.maxScrollExtent - 150) {
        final auth = context.read<AuthState>();
        if (auth.api != null && _selectedChat != null) {
          _chatService.loadMessages(
            auth.api!,
            _selectedChat!.id,
            topicId: _selectedTopic?.id ?? 0,
            loadMore: true,
          );
        }
      }
    }
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
  }

  void _selectChat(ChatItem chat) {
    setState(() {
      _selectedChat = chat;
      _selectedTopic = null;
    });

    final auth = context.read<AuthState>();
    if (auth.api == null) return;

    _chatService.markLocalRead(chat.id);

    if (chat.isForum) {
      _chatService.loadTopics(auth.api!, chat.id).then((topics) {
        if (topics.isNotEmpty && mounted) {
          _selectTopic(topics.first);
        }
      });
    } else {
      _chatService.loadMessages(auth.api!, chat.id, topicId: 0);
    }
  }

  void _selectTopic(TopicItem topic) {
    setState(() => _selectedTopic = topic);
    final auth = context.read<AuthState>();
    if (auth.api != null && _selectedChat != null) {
      _chatService.loadMessages(auth.api!, _selectedChat!.id, topicId: topic.id);
    }
  }

  Future<void> _handleSend() async {
    final text = _textController.text.trim();
    if (text.isEmpty || _selectedChat == null) return;

    final auth = context.read<AuthState>();
    if (auth.api == null) return;

    _textController.clear();
    setState(() => _showEmojiBar = false);

    try {
      await _chatService.sendMessage(
        auth.api!,
        _selectedChat!.id,
        topicId: _selectedTopic?.id ?? 0,
        body: text,
        kind: 'text',
      );
      _scrollToBottom();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Ошибка отправки сообщения')),
        );
      }
    }
  }

  void _showNewChatDialog(BuildContext context) {
    final auth = context.read<AuthState>();
    if (auth.api == null) return;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _NewChatSheet(
        api: auth.api!,
        onChatSelected: (chat) {
          Navigator.of(ctx).pop();
          _selectChat(chat);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isWide = MediaQuery.of(context).size.width >= 720;

    return AnimatedBuilder(
      animation: _chatService,
      builder: (context, _) {
        if (isWide) {
          return _buildWideLayout(theme);
        }
        return _buildMobileLayout(theme);
      },
    );
  }

  Widget _buildWideLayout(ThemeData theme) {
    return Row(
      children: [
        SizedBox(
          width: 300,
          child: _buildChatList(theme),
        ),
        VerticalDivider(width: 1, color: theme.colorScheme.outlineVariant),
        if (_selectedChat?.isForum == true) ...[
          SizedBox(
            width: 220,
            child: _buildTopicsList(theme),
          ),
          VerticalDivider(width: 1, color: theme.colorScheme.outlineVariant),
        ],
        Expanded(
          child: _selectedChat != null
              ? _buildChatArea(theme)
              : _buildEmptyState(theme),
        ),
      ],
    );
  }

  Widget _buildMobileLayout(ThemeData theme) {
    if (_selectedChat == null) {
      return _buildChatList(theme);
    }
    final displayTitle = _resolveChatTitle(_selectedChat!);
    final initials = _getInitials(displayTitle);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        setState(() {
          _selectedChat = null;
          _selectedTopic = null;
        });
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => setState(() {
              _selectedChat = null;
              _selectedTopic = null;
            }),
          ),
          titleSpacing: 0,
          title: Row(
            children: [
              CircleAvatar(
                radius: 17,
                backgroundColor: _selectedChat?.isForum == true
                    ? theme.colorScheme.tertiaryContainer
                    : theme.colorScheme.primaryContainer,
                foregroundColor: _selectedChat?.isForum == true
                    ? theme.colorScheme.onTertiaryContainer
                    : theme.colorScheme.onPrimaryContainer,
                child: Text(
                  _selectedChat?.isForum == true ? '🏛️' : initials,
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      displayTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                    ),
                    if (_selectedTopic != null)
                      Text(
                        '${_selectedTopic!.iconEmoji} ${_selectedTopic!.title}',
                        style: TextStyle(fontSize: 11, color: theme.colorScheme.primary),
                      )
                    else
                      Text(
                        'В сети',
                        style: TextStyle(fontSize: 11, color: theme.colorScheme.primary),
                      ),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.phone_outlined),
              tooltip: 'Аудиозвонок',
              onPressed: () => _startCall(isVideo: false),
            ),
            IconButton(
              icon: const Icon(Icons.videocam_outlined),
              tooltip: 'Видеозвонок',
              onPressed: () => _startCall(isVideo: true),
            ),
            IconButton(
              icon: const Icon(Icons.settings_outlined),
              tooltip: 'Настройки камеры/микрофона',
              onPressed: _showMediaSettingsDialog,
            ),
            if (_selectedChat?.isForum == true)
              IconButton(
                icon: const Icon(Icons.forum_outlined),
                tooltip: 'Темы форума',
                onPressed: () => _showTopicsBottomSheet(theme),
              ),
          ],
        ),
        body: _buildChatArea(theme),
      ),
    );
  }

  Widget _buildChatList(ThemeData theme) {
    final chats = _chatService.chats;

    return Scaffold(
      appBar: AppBar(
        title: const Text('💬 Корпоративный чат'),
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Обновить',
            onPressed: () {
              final auth = context.read<AuthState>();
              if (auth.api != null) _chatService.loadChats(auth.api!);
            },
          ),
          IconButton(
            icon: const Icon(Icons.add_comment_outlined),
            tooltip: 'Новый чат',
            onPressed: () => _showNewChatDialog(context),
          ),
        ],
      ),
      body: _chatService.isLoadingChats && chats.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : chats.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 64,
                          height: 64,
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primary.withValues(alpha: 0.12),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(Icons.forum_rounded, size: 32, color: theme.colorScheme.primary),
                        ),
                        const SizedBox(height: 16),
                        const Text(
                          'Корпоративный мессенджер',
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Общайтесь с коллегами, обсуждайте проекты в тематических форумах и звоните через P2P.',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 13, color: theme.colorScheme.onSurfaceVariant),
                        ),
                        const SizedBox(height: 20),
                        FilledButton.icon(
                          onPressed: () => _showNewChatDialog(context),
                          icon: const Icon(Icons.person_add_alt_1_outlined),
                          label: const Text('Написать коллеге'),
                        ),
                      ],
                    ),
                  ),
                )
              : ListView.separated(
                  itemCount: chats.length,
                  separatorBuilder: (_, __) => Divider(
                    height: 1,
                    color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
                  ),
                  itemBuilder: (context, index) {
                    final chat = chats[index];
                    final isSelected = _selectedChat?.id == chat.id;
                    final displayTitle = _resolveChatTitle(chat);
                    final initials = _getInitials(displayTitle);

                    return ListTile(
                      selected: isSelected,
                      selectedTileColor: theme.colorScheme.primaryContainer.withValues(alpha: 0.2),
                      leading: CircleAvatar(
                        backgroundColor: chat.isForum
                            ? theme.colorScheme.tertiaryContainer
                            : (chat.kind == 'direct'
                                ? theme.colorScheme.primaryContainer
                                : theme.colorScheme.secondaryContainer),
                        foregroundColor: chat.isForum
                            ? theme.colorScheme.onTertiaryContainer
                            : (chat.kind == 'direct'
                                ? theme.colorScheme.onPrimaryContainer
                                : theme.colorScheme.onSecondaryContainer),
                        child: Text(
                          chat.isForum ? '🏛️' : initials,
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                        ),
                      ),
                      title: Text(
                        displayTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                      ),
                      subtitle: chat.description.isNotEmpty
                          ? Text(
                              chat.description,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            )
                          : null,
                      trailing: chat.unreadCount > 0
                          ? Badge(
                              label: Text('${chat.unreadCount}'),
                              backgroundColor: theme.colorScheme.primary,
                            )
                          : null,
                      onTap: () => _selectChat(chat),
                    );
                  },
                ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showNewChatDialog(context),
        tooltip: 'Новый чат',
        child: const Icon(Icons.edit_outlined),
      ),
    );
  }

  Widget _buildTopicsList(ThemeData theme) {
    if (_selectedChat == null) return const SizedBox.shrink();
    final topics = _chatService.getTopics(_selectedChat!.id);

    return Scaffold(
      backgroundColor: theme.colorScheme.surfaceContainerLowest,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('Темы форума', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
      ),
      body: ListView.builder(
        itemCount: topics.length,
        itemBuilder: (context, index) {
          final topic = topics[index];
          final isSelected = _selectedTopic?.id == topic.id;

          return ListTile(
            dense: true,
            selected: isSelected,
            selectedTileColor: theme.colorScheme.primaryContainer.withValues(alpha: 0.3),
            leading: Text(topic.iconEmoji, style: const TextStyle(fontSize: 16)),
            title: Text(
              topic.title,
              style: TextStyle(
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                fontSize: 13,
              ),
            ),
            trailing: topic.unreadCount > 0
                ? Badge(
                    label: Text('${topic.unreadCount}'),
                    backgroundColor: theme.colorScheme.primary,
                  )
                : null,
            onTap: () => _selectTopic(topic),
          );
        },
      ),
    );
  }

  void _showTopicsBottomSheet(ThemeData theme) {
    if (_selectedChat == null) return;
    final topics = _chatService.getTopics(_selectedChat!.id);

    showModalBottomSheet<void>(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('Выберите тему форума', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              ),
              Expanded(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: topics.length,
                  itemBuilder: (context, index) {
                    final t = topics[index];
                    return ListTile(
                      leading: Text(t.iconEmoji),
                      title: Text(t.title),
                      onTap: () {
                        Navigator.pop(context);
                        _selectTopic(t);
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildChatArea(ThemeData theme) {
    final chatId = _selectedChat?.id ?? '';
    final topicId = _selectedTopic?.id ?? 0;
    final messages = _chatService.getMessages(chatId, topicId);
    final auth = context.read<AuthState>();
    final currentUsername = auth.username;
    final currentUserId = auth.currentUser?['id']?.toString() ?? '';
    final isWide = MediaQuery.of(context).size.width >= 720;

    return Stack(
      children: [
        Column(
          children: [
            if (isWide && _selectedChat != null)
              _buildWideChatHeader(theme),
            Expanded(
              child: messages.isEmpty
                  ? Center(
                      child: Text(
                        'Нет сообщений в этой теме',
                        style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                      ),
                    )
                  : ListView.builder(
                      controller: _scrollController,
                      reverse: true, // Индекс 0 внизу экрана
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      itemCount: messages.length,
                      itemBuilder: (context, index) {
                        final msg = messages[index];
                        final isMe = msg.senderId == currentUserId ||
                            msg.senderName == currentUsername ||
                            msg.senderId == currentUsername;
                        return _buildMessageBubble(theme, msg, isMe);
                      },
                    ),
            ),
            _buildComposer(theme),
          ],
        ),
        if (_showScrollToBottom)
          Positioned(
            right: 16,
            bottom: 80,
            child: FloatingActionButton.small(
              onPressed: _scrollToBottom,
              backgroundColor: theme.colorScheme.primaryContainer,
              foregroundColor: theme.colorScheme.onPrimaryContainer,
              child: const Icon(Icons.arrow_downward),
            ),
          ),
      ],
    );
  }

  Widget _buildMessageBubble(ThemeData theme, ChatMessage msg, bool isMe) {
    final timeStr = '${msg.createdAt.hour.toString().padLeft(2, '0')}:${msg.createdAt.minute.toString().padLeft(2, '0')}';
    final senderTitle = _resolveSenderName(msg);

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: isMe
              ? theme.colorScheme.primary
              : theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(isMe ? 16 : 4),
            bottomRight: Radius.circular(isMe ? 4 : 16),
          ),
        ),
        child: Column(
          crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            if (!isMe)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(
                  senderTitle,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.primary,
                  ),
                ),
              ),
            Text(
              msg.body,
              style: TextStyle(
                fontSize: 14,
                color: isMe ? Colors.white : theme.colorScheme.onSurface,
              ),
            ),
            if (msg.hasAttachments)
              ...msg.attachments.map((att) => _buildAttachmentCard(theme, att, isMe)),
            const SizedBox(height: 3),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  timeStr,
                  style: TextStyle(
                    fontSize: 10,
                    color: isMe ? Colors.white70 : theme.colorScheme.outline,
                  ),
                ),
                if (isMe) ...[
                  const SizedBox(width: 4),
                  const Icon(Icons.done_all, size: 12, color: Colors.white70),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  bool _isUuid(String s) {
    return RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$').hasMatch(s.trim());
  }

  String _resolveChatTitle(ChatItem chat) {
    final title = chat.title.trim();
    if (_isUuid(title)) {
      for (final c in _chatService.contacts) {
        if (c.username == title) {
          return c.displayName.isNotEmpty ? c.displayName : c.username;
        }
      }
      return 'Диалог с сотрудником';
    }
    return title.isNotEmpty ? title : 'Диалог';
  }

  String _resolveSenderName(ChatMessage msg) {
    if (msg.senderName.isNotEmpty && !_isUuid(msg.senderName)) {
      return msg.senderName;
    }
    for (final c in _chatService.contacts) {
      if (c.username == msg.senderId || c.displayName == msg.senderName) {
        return c.displayName.isNotEmpty ? c.displayName : c.username;
      }
    }
    return msg.senderName.isNotEmpty ? msg.senderName : msg.senderId;
  }

  String _getInitials(String title) {
    if (title.isEmpty) return 'U';
    final parts = title.trim().split(RegExp(r'\s+'));
    if (parts.length >= 2) {
      return (parts[0][0] + parts[1][0]).toUpperCase();
    }
    return title.substring(0, title.length >= 2 ? 2 : 1).toUpperCase();
  }

  Widget _buildComposer(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(top: BorderSide(color: theme.colorScheme.outlineVariant)),
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_showEmojiBar)
              Container(
                height: 44,
                margin: const EdgeInsets.only(bottom: 6),
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: _quickEmojis.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 4),
                  itemBuilder: (context, i) {
                    final em = _quickEmojis[i];
                    return InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () {
                        _textController.text += em;
                        _textController.selection = TextSelection.fromPosition(
                          TextPosition(offset: _textController.text.length),
                        );
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        alignment: Alignment.center,
                        child: Text(em, style: const TextStyle(fontSize: 20)),
                      ),
                    );
                  },
                ),
              ),
            Row(
              children: [
                IconButton(
                  icon: Icon(
                    Icons.emoji_emotions_outlined,
                    color: _showEmojiBar ? theme.colorScheme.primary : null,
                  ),
                  tooltip: 'Смайлики',
                  onPressed: () => setState(() => _showEmojiBar = !_showEmojiBar),
                ),
                if (_isUploading)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 10),
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                else
                  IconButton(
                    icon: const Icon(Icons.attach_file),
                    tooltip: 'Прикрепить файл',
                    onPressed: _handlePickAndSendFile,
                  ),
                Expanded(
                  child: TextField(
                    controller: _textController,
                    maxLines: 3,
                    minLines: 1,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _handleSend(),
                    decoration: InputDecoration(
                      hintText: _selectedTopic != null
                          ? 'Сообщение в ${_selectedTopic!.title}...'
                          : 'Напишите сообщение...',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide.none,
                      ),
                      filled: true,
                      fillColor: theme.colorScheme.surfaceContainerHighest,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  icon: const Icon(Icons.send),
                  onPressed: _handleSend,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWideChatHeader(ThemeData theme) {
    if (_selectedChat == null) return const SizedBox.shrink();
    final chatTitle = _resolveChatTitle(_selectedChat!);
    final initials = _getInitials(chatTitle);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(bottom: BorderSide(color: theme.colorScheme.outlineVariant)),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 19,
            backgroundColor: _selectedChat!.isForum
                ? theme.colorScheme.tertiaryContainer
                : theme.colorScheme.primaryContainer,
            foregroundColor: _selectedChat!.isForum
                ? theme.colorScheme.onTertiaryContainer
                : theme.colorScheme.onPrimaryContainer,
            child: Text(
              _selectedChat!.isForum ? '🏛️' : initials,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  chatTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                Text(
                  _selectedTopic != null
                      ? '${_selectedTopic!.iconEmoji} ${_selectedTopic!.title}'
                      : 'В сети',
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.phone_outlined),
            tooltip: 'Аудиозвонок',
            onPressed: () => _startCall(isVideo: false),
          ),
          IconButton(
            icon: const Icon(Icons.videocam_outlined),
            tooltip: 'Видеозвонок',
            onPressed: () => _startCall(isVideo: true),
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Настройки камеры/микрофона',
            onPressed: _showMediaSettingsDialog,
          ),
        ],
      ),
    );
  }

  Widget _buildAttachmentCard(ThemeData theme, Map<String, dynamic> att, bool isMe) {
    final name = att['name']?.toString() ?? 'Файл';
    final sizeBytes = (att['size'] as num?)?.toInt() ?? 0;
    final attId = att['id']?.toString() ?? '';
    final sizeStr = sizeBytes > 1024 * 1024
        ? '${(sizeBytes / (1024 * 1024)).toStringAsFixed(1)} МБ'
        : '${(sizeBytes / 1024).toStringAsFixed(1)} КБ';
    final isImg = name.toLowerCase().endsWith('.png') ||
        name.toLowerCase().endsWith('.jpg') ||
        name.toLowerCase().endsWith('.jpeg') ||
        name.toLowerCase().endsWith('.webp');

    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: isMe
            ? Colors.white.withValues(alpha: 0.15)
            : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.8),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isMe
              ? Colors.white24
              : theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: isMe
                  ? Colors.white24
                  : theme.colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              isImg ? Icons.image_outlined : Icons.insert_drive_file_outlined,
              size: 20,
              color: isMe ? Colors.white : theme.colorScheme.primary,
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: isMe ? Colors.white : theme.colorScheme.onSurface,
                  ),
                ),
                Text(
                  sizeStr,
                  style: TextStyle(
                    fontSize: 11,
                    color: isMe ? Colors.white70 : theme.colorScheme.outline,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: Icon(
              Icons.download_rounded,
              size: 20,
              color: isMe ? Colors.white : theme.colorScheme.primary,
            ),
            tooltip: 'Скачать файл',
            onPressed: () => _downloadAndSaveFile(attId, name),
          ),
        ],
      ),
    );
  }

  Future<void> _handlePickAndSendFile() async {
    final auth = context.read<AuthState>();
    if (auth.api == null || _selectedChat == null) return;

    try {
      final result = await FilePicker.platform.pickFiles(withData: true);
      if (result == null || result.files.isEmpty) return;
      final file = result.files.first;
      final bytes = file.bytes;
      if (bytes == null || bytes.isEmpty) return;

      setState(() => _isUploading = true);
      await _chatService.sendAttachment(
        auth.api!,
        _selectedChat!.id,
        topicId: _selectedTopic?.id ?? 0,
        fileName: file.name,
        bytes: bytes,
      );
      _scrollToBottom();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Ошибка отправки файла: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isUploading = false);
    }
  }

  Future<void> _downloadAndSaveFile(String attId, String fileName) async {
    final auth = context.read<AuthState>();
    if (auth.api == null || attId.isEmpty) return;

    try {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Скачивание файла...'), duration: Duration(seconds: 1)),
      );
      final bytes = await auth.api!.downloadChatAttachment(attId);
      final outputFilePath = await FilePicker.platform.saveFile(
        dialogTitle: 'Сохранить файл',
        fileName: fileName,
        bytes: bytes,
      );
      if (outputFilePath != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Файл сохранён: $fileName')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Ошибка скачивания: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    }
  }

  Future<void> _showMediaSettingsDialog() async {
    List<MediaDeviceInfo> devices = [];
    try {
      devices = await navigator.mediaDevices.enumerateDevices();
    } catch (_) {}

    final audioInputs = devices.where((d) => d.kind == 'audioinput').toList();
    final videoInputs = devices.where((d) => d.kind == 'videoinput').toList();

    if (!mounted) return;

    String? selectedAudio = audioInputs.isNotEmpty ? audioInputs.first.deviceId : null;
    String? selectedVideo = videoInputs.isNotEmpty ? videoInputs.first.deviceId : null;

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final theme = Theme.of(context);
            return AlertDialog(
              title: const Row(
                children: [
                  Icon(Icons.settings_voice_outlined),
                  SizedBox(width: 8),
                  Text('Настройки звонков'),
                ],
              ),
              content: SizedBox(
                width: 400,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Микрофон', style: TextStyle(fontWeight: FontWeight.bold, color: theme.colorScheme.primary)),
                    const SizedBox(height: 6),
                    if (audioInputs.isEmpty)
                      const Text('Микрофоны не найдены', style: TextStyle(fontSize: 13, color: Colors.grey))
                    else
                      DropdownButtonFormField<String>(
                        isExpanded: true,
                        initialValue: selectedAudio,
                        decoration: InputDecoration(
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        ),
                        items: audioInputs.map((d) {
                          return DropdownMenuItem(
                            value: d.deviceId,
                            child: Text(
                              d.label.isNotEmpty ? d.label : 'Микрофон ${d.deviceId.substring(0, d.deviceId.length > 6 ? 6 : d.deviceId.length)}',
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 13),
                            ),
                          );
                        }).toList(),
                        onChanged: (val) => setDialogState(() => selectedAudio = val),
                      ),
                    const SizedBox(height: 16),
                    Text('Камера', style: TextStyle(fontWeight: FontWeight.bold, color: theme.colorScheme.primary)),
                    const SizedBox(height: 6),
                    if (videoInputs.isEmpty)
                      const Text('Камеры не найдены', style: TextStyle(fontSize: 13, color: Colors.grey))
                    else
                      DropdownButtonFormField<String>(
                        isExpanded: true,
                        initialValue: selectedVideo,
                        decoration: InputDecoration(
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        ),
                        items: videoInputs.map((d) {
                          return DropdownMenuItem(
                            value: d.deviceId,
                            child: Text(
                              d.label.isNotEmpty ? d.label : 'Камера ${d.deviceId.substring(0, d.deviceId.length > 6 ? 6 : d.deviceId.length)}',
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 13),
                            ),
                          );
                        }).toList(),
                        onChanged: (val) => setDialogState(() => selectedVideo = val),
                      ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Готово'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _startCall({required bool isVideo}) {
    if (_selectedChat == null) return;
    final chatTitle = _resolveChatTitle(_selectedChat!);

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        var isMuted = false;
        var isCameraOff = !isVideo;

        return StatefulBuilder(
          builder: (context, setCallState) {
            final theme = Theme.of(context);
            return AlertDialog(
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              content: SizedBox(
                width: 340,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircleAvatar(
                      radius: 40,
                      backgroundColor: theme.colorScheme.primaryContainer,
                      foregroundColor: theme.colorScheme.onPrimaryContainer,
                      child: Text(
                        _getInitials(chatTitle),
                        style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      chatTitle,
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      isVideo ? 'Защищённый видеозвонок' : 'Защищённый аудиозвонок',
                      style: TextStyle(fontSize: 13, color: theme.colorScheme.outline),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'Установление P2P соединения...',
                          style: TextStyle(fontSize: 12, color: theme.colorScheme.primary),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        IconButton.filledTonal(
                          icon: Icon(isMuted ? Icons.mic_off : Icons.mic),
                          tooltip: isMuted ? 'Включить микрофон' : 'Выключить микрофон',
                          onPressed: () => setCallState(() => isMuted = !isMuted),
                        ),
                        if (isVideo)
                          IconButton.filledTonal(
                            icon: Icon(isCameraOff ? Icons.videocam_off : Icons.videocam),
                            tooltip: isCameraOff ? 'Включить камеру' : 'Выключить камеру',
                            onPressed: () => setCallState(() => isCameraOff = !isCameraOff),
                          ),
                        IconButton.filled(
                          style: IconButton.styleFrom(backgroundColor: theme.colorScheme.error),
                          icon: const Icon(Icons.call_end, color: Colors.white),
                          tooltip: 'Завершить вызов',
                          onPressed: () => Navigator.pop(ctx),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildEmptyState(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.chat_bubble_outline, size: 64, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(height: 16),
          Text(
            'Выберите диалог или топик форума',
            style: TextStyle(
              fontSize: 16,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _NewChatSheet extends StatefulWidget {
  final dynamic api;
  final ValueChanged<ChatItem> onChatSelected;

  const _NewChatSheet({
    required this.api,
    required this.onChatSelected,
  });

  @override
  State<_NewChatSheet> createState() => _NewChatSheetState();
}

class _NewChatSheetState extends State<_NewChatSheet> with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _groupTitleController = TextEditingController();
  final TextEditingController _groupDescController = TextEditingController();
  bool _isForum = false;
  bool _isLoading = false;
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    ChatService.instance.loadContacts(widget.api);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _searchController.dispose();
    _groupTitleController.dispose();
    _groupDescController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final contacts = ChatService.instance.contacts.where((c) {
      if (_searchQuery.isEmpty) return true;
      final q = _searchQuery.toLowerCase();
      return c.username.toLowerCase().contains(q) ||
          c.displayName.toLowerCase().contains(q) ||
          c.title.toLowerCase().contains(q);
    }).toList();

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SizedBox(
        height: 520,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Row(
                children: [
                  const Text(
                    'Новый диалог или канал',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            TabBar(
              controller: _tabController,
              tabs: const [
                Tab(icon: Icon(Icons.people_outline), text: 'Сотрудники'),
                Tab(icon: Icon(Icons.group_add_outlined), text: 'Группа / Форум'),
              ],
            ),
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  // Вкладка 1: Список сотрудников компании
                  Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: TextField(
                          controller: _searchController,
                          decoration: InputDecoration(
                            prefixIcon: const Icon(Icons.search),
                            hintText: 'Поиск по имени или логину...',
                            isDense: true,
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                          onChanged: (v) => setState(() => _searchQuery = v),
                        ),
                      ),
                      Expanded(
                        child: contacts.isEmpty
                            ? Center(
                                child: Text(
                                  'Сотрудники не найдены',
                                  style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                                ),
                              )
                            : ListView.separated(
                                itemCount: contacts.length,
                                separatorBuilder: (_, __) => const Divider(height: 1),
                                itemBuilder: (ctx, i) {
                                  final c = contacts[i];
                                  final letter = c.displayName.isNotEmpty
                                      ? c.displayName[0].toUpperCase()
                                      : c.username[0].toUpperCase();

                                  return ListTile(
                                    leading: CircleAvatar(
                                      backgroundColor: theme.colorScheme.primaryContainer,
                                      foregroundColor: theme.colorScheme.onPrimaryContainer,
                                      child: Text(letter),
                                    ),
                                    title: Text(c.displayName.isNotEmpty ? c.displayName : c.username),
                                    subtitle: Text(
                                      c.title.isNotEmpty ? c.title : (c.email.isNotEmpty ? c.email : '@${c.username}'),
                                      style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant),
                                    ),
                                    trailing: const Icon(Icons.chevron_right),
                                    onTap: () async {
                                      setState(() => _isLoading = true);
                                      try {
                                        final chat = await ChatService.instance.createDirectChat(
                                          widget.api,
                                          c.username,
                                          targetName: c.displayName,
                                        );
                                        widget.onChatSelected(chat);
                                      } finally {
                                        if (mounted) setState(() => _isLoading = false);
                                      }
                                    },
                                  );
                                },
                              ),
                      ),
                    ],
                  ),

                  // Вкладка 2: Создать группу или форум
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        TextField(
                          controller: _groupTitleController,
                          decoration: InputDecoration(
                            labelText: 'Название группы или канала *',
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                        ),
                        const SizedBox(height: 14),
                        TextField(
                          controller: _groupDescController,
                          maxLines: 2,
                          decoration: InputDecoration(
                            labelText: 'Описание (опционально)',
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                        ),
                        const SizedBox(height: 14),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('🏛️ Форум с темами'),
                          subtitle: const Text('Позволяет создавать отдельные топики (как в Telegram)'),
                          value: _isForum,
                          onChanged: (v) => setState(() => _isForum = v),
                        ),
                        const Spacer(),
                        FilledButton(
                          onPressed: _isLoading
                              ? null
                              : () async {
                                  final title = _groupTitleController.text.trim();
                                  if (title.isEmpty) return;

                                  setState(() => _isLoading = true);
                                  try {
                                    final chat = await ChatService.instance.createGroupChat(
                                      widget.api,
                                      title: title,
                                      description: _groupDescController.text.trim(),
                                      isForum: _isForum,
                                    );
                                    widget.onChatSelected(chat);
                                  } finally {
                                    if (mounted) setState(() => _isLoading = false);
                                  }
                                },
                          child: _isLoading
                              ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                              : const Text('Создать канал'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
