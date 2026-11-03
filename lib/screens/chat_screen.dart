import 'package:flutter/material.dart';
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
  bool _isSecretMode = false;
  bool _showScrollToBottom = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final auth = context.read<AuthState>();
      if (auth.api != null) {
        _chatService.loadChats(auth.api!);
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
    // В reverse: true скролл в 0 — это самый низ экрана
    if (_scrollController.hasClients) {
      final offset = _scrollController.offset;
      if (offset > 250 && !_showScrollToBottom) {
        setState(() => _showScrollToBottom = true);
      } else if (offset <= 250 && _showScrollToBottom) {
        setState(() => _showScrollToBottom = false);
      }

      // Пагинация: приближение к верхнему краю (старым сообщениям)
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

    if (chat.isForum) {
      _chatService.loadTopics(auth.api!, chat.id).then((_) {
        final topics = _chatService.getTopics(chat.id);
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

    final kind = _isSecretMode ? 'secret' : 'text';
    final secretTtl = _isSecretMode ? 60 : null;

    _textController.clear();
    if (_isSecretMode) {
      setState(() => _isSecretMode = false);
    }

    try {
      await _chatService.sendMessage(
        auth.api!,
        _selectedChat!.id,
        topicId: _selectedTopic?.id ?? 0,
        body: text,
        kind: kind,
        secretTtl: secretTtl,
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
          width: 280,
          child: _buildChatList(theme),
        ),
        VerticalDivider(width: 1, color: theme.colorScheme.outlineVariant),
        if (_selectedChat?.isForum == true) ...[
          SizedBox(
            width: 200,
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
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_selectedChat?.title ?? '', style: const TextStyle(fontSize: 16)),
              if (_selectedTopic != null)
                Text(
                  '${_selectedTopic!.iconEmoji} ${_selectedTopic!.title}',
                  style: TextStyle(fontSize: 12, color: theme.colorScheme.primary),
                ),
            ],
          ),
          actions: [
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
      ),
      body: _chatService.isLoadingChats && chats.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : chats.isEmpty
              ? Center(
                  child: Text(
                    'Нет доступных диалогов',
                    style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
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

                    return ListTile(
                      selected: isSelected,
                      selectedTileColor: theme.colorScheme.primaryContainer.withValues(alpha: 0.2),
                      leading: CircleAvatar(
                        backgroundColor: theme.colorScheme.surfaceContainerHighest,
                        child: Text(chat.isForum ? '🏛️' : (chat.kind == 'direct' ? '👤' : '👥')),
                      ),
                      title: Text(
                        chat.title,
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

    return Stack(
      children: [
        Column(
          children: [
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
                      reverse: true, // Индекс 0 внизу экрана!
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
    final isSecret = msg.kind == 'secret';

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: isSecret
              ? theme.colorScheme.errorContainer.withValues(alpha: 0.3)
              : isMe
                  ? theme.colorScheme.primaryContainer
                  : theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(isMe ? 16 : 4),
            bottomRight: Radius.circular(isMe ? 4 : 16),
          ),
          border: isSecret
              ? Border.all(color: theme.colorScheme.error.withValues(alpha: 0.5))
              : null,
        ),
        child: Column(
          crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            if (!isMe)
              Text(
                msg.senderName,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.primary,
                ),
              ),
            if (isSecret)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.local_fire_department, size: 14, color: theme.colorScheme.error),
                    const SizedBox(width: 4),
                    Text(
                      'Сгорающий секрет (60с)',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ],
                ),
              ),
            Text(
              msg.body,
              style: TextStyle(
                fontSize: 14,
                color: isSecret
                    ? theme.colorScheme.onErrorContainer
                    : isMe
                        ? theme.colorScheme.onPrimaryContainer
                        : theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
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
            if (_isSecretMode)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    Icon(Icons.lock_clock, size: 16, color: theme.colorScheme.error),
                    const SizedBox(width: 6),
                    Text(
                      'Одноразовый пароль (самоуничтожится через 60 сек)',
                      style: TextStyle(
                        fontSize: 11,
                        color: theme.colorScheme.error,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            Row(
              children: [
                IconButton(
                  icon: Icon(
                    Icons.lock_outline,
                    color: _isSecretMode ? theme.colorScheme.error : null,
                  ),
                  tooltip: 'Сгорающий пароль',
                  onPressed: () => setState(() => _isSecretMode = !_isSecretMode),
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
