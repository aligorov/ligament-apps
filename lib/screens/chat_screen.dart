import 'dart:async';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../api/client.dart';
import '../models/chat_models.dart';
import '../services/auth_state.dart';
import '../services/chat_service.dart';
import '../services/call_session_manager.dart';
import '../widgets/waveform_bubble.dart';
import '../widgets/neural_mesh_background.dart';
import '../widgets/window_caption_controls.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  final TextEditingController _textController = TextEditingController();
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final ChatService _chatService = ChatService.instance;

  ChatItem? _selectedChat;
  TopicItem? _selectedTopic;
  bool _showScrollToBottom = false;
  bool _showEmojiBar = false;
  bool _isUploading = false;
  String _searchQuery = '';
  String _selectedCategory = 'all';
  final Map<String, String> _drafts = {};
  ChatMessage? _replyingTo;
  ChatMessage? _editingMessage;
  final Set<String> _downloadingPreviews = {};

  static const List<String> _quickEmojis = [
    '👍', '❤️', '🔥', '😂', '😊', '🎉', '🚀', '✅', '❌', '👋', '🤔', '🤝', '👏', '💯', '☕'
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final auth = context.read<AuthState>();
      if (auth.api != null) {
        _chatService.connectWebSocket(auth.api!);
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
    _chatService.setActiveChat(null);
    WidgetsBinding.instance.removeObserver(this);
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _textController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      final auth = context.read<AuthState>();
      if (auth.api != null) {
        _chatService.connectWebSocket(auth.api!);
      }
    }
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
    if (_selectedChat != null) {
      final prevKey = '${_selectedChat!.id}:${_selectedTopic?.id ?? 0}';
      if (_textController.text.isNotEmpty) {
        _drafts[prevKey] = _textController.text;
      } else {
        _drafts.remove(prevKey);
      }
    }

    final newKey = '${chat.id}:0';
    _textController.text = _drafts[newKey] ?? '';

    setState(() {
      _selectedChat = chat;
      _selectedTopic = null;
      _replyingTo = null;
    });

    final auth = context.read<AuthState>();
    if (auth.api == null) return;

    _chatService.setActiveChat(chat.id, 0);
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
    if (_selectedChat != null) {
      final prevKey = '${_selectedChat!.id}:${_selectedTopic?.id ?? 0}';
      if (_textController.text.isNotEmpty) {
        _drafts[prevKey] = _textController.text;
      } else {
        _drafts.remove(prevKey);
      }
      final newKey = '${_selectedChat!.id}:${topic.id}';
      _textController.text = _drafts[newKey] ?? '';
    }

    setState(() {
      _selectedTopic = topic;
      _replyingTo = null;
    });
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

    if (_editingMessage != null) {
      final msgToEdit = _editingMessage!;
      _textController.clear();
      setState(() {
        _editingMessage = null;
      });
      try {
        await _chatService.editMessage(
          auth.api!,
          _selectedChat!.id,
          msgToEdit.id,
          topicId: _selectedTopic?.id ?? 0,
          body: text,
        );
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Не удалось изменить сообщение')),
          );
        }
      }
      return;
    }

    final replyId = _replyingTo?.id;
    _textController.clear();
    final draftKey = '${_selectedChat!.id}:${_selectedTopic?.id ?? 0}';
    _drafts.remove(draftKey);

    setState(() {
      _showEmojiBar = false;
      _replyingTo = null;
    });

    try {
      await _chatService.sendMessage(
        auth.api!,
        _selectedChat!.id,
        topicId: _selectedTopic?.id ?? 0,
        body: text,
        kind: 'text',
        replyToId: replyId,
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

  void _showCreateTopicDialog(BuildContext context) {
    final auth = context.read<AuthState>();
    if (auth.api == null || _selectedChat == null) return;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _CreateTopicSheet(
        api: auth.api!,
        chatId: _selectedChat!.id,
        onTopicCreated: (topic) {
          Navigator.of(ctx).pop();
          _selectTopic(topic);
        },
      ),
    );
  }

  bool _canManageTopics(AuthState auth) {
    if (_selectedChat == null) return false;
    final myRole = _selectedChat!.myRole.toLowerCase();
    if (myRole == 'admin' || myRole == 'moderator') return true;
    if (auth.isAdmin) return true;
    final userRole = (auth.currentUser?['role']?.toString() ?? '').toLowerCase();
    return userRole == 'admin' || userRole == 'superadmin' || userRole == 'chat_admin' || userRole == 'moderator' || userRole == 'operator';
  }

  void _showEditTopicDialog(BuildContext context, TopicItem topic) {
    final auth = context.read<AuthState>();
    if (auth.api == null || _selectedChat == null) return;
    final isManager = _canManageTopics(auth);

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _EditTopicSheet(
        api: auth.api!,
        chatId: _selectedChat!.id,
        topic: topic,
        isManager: isManager,
        onTopicUpdated: (updated) {
          Navigator.of(ctx).pop();
          if (_selectedTopic?.id == updated.id) {
            setState(() => _selectedTopic = updated);
          }
        },
        onTopicDeleted: () {
          Navigator.of(ctx).pop();
          if (_selectedTopic?.id == topic.id) {
            final remaining = _chatService.getTopics(_selectedChat!.id);
            if (remaining.isNotEmpty) {
              _selectTopic(remaining.first);
            } else {
              setState(() => _selectedTopic = null);
            }
          }
        },
      ),
    );
  }

  void _showMembersDialog(BuildContext context) {
    final auth = context.read<AuthState>();
    if (auth.api == null || _selectedChat == null) return;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _ChatMembersSheet(
        api: auth.api!,
        chat: _selectedChat!,
      ),
    );
  }

  Widget _buildChatSubtitle(ThemeData theme, ChatItem chat) {
    if (chat.isForum && _selectedTopic != null) {
      return Text(
        '${_selectedTopic!.iconEmoji} ${_selectedTopic!.title}',
        style: TextStyle(
          fontSize: 11,
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w500,
        ),
      );
    }

    if (chat.kind == 'direct') {
      final peer = chat.peerUserId.isNotEmpty ? chat.peerUserId : chat.title;
      final p = _chatService.getPresence(peer);
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              color: p.statusColor,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              p.fullStatusDisplay,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                color: p.isOnline || p.status == 'vacation'
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      );
    }

    return Text(
      chat.description.isNotEmpty ? chat.description : 'Групповой чат',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontSize: 11, color: theme.colorScheme.onSurfaceVariant),
    );
  }

  Widget _buildMyStatusAction(ThemeData theme) {
    final auth = context.watch<AuthState>();
    final myPresence = _chatService.getPresence(auth.username);

    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: () => _showPresenceStatusDialog(context),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: myPresence.statusColor.withValues(alpha: 0.5)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: myPresence.statusColor,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              myPresence.statusLabel,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showPresenceStatusDialog(BuildContext context) {
    final auth = context.read<AuthState>();
    if (auth.api == null) return;
    final currentUsername = auth.username;
    final myPresence = _chatService.getPresence(currentUsername);

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _PresenceStatusSheet(
        api: auth.api!,
        initialStatus: myPresence.status,
        initialStatusText: myPresence.statusText,
        onStatusChanged: (status, statusText) async {
          Navigator.of(ctx).pop();
          await _chatService.setMyStatus(auth.api!, status, statusText: statusText);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final width = MediaQuery.of(context).size.width;
    final isWide = width >= 600;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: NeuralMeshBackground(
        child: AnimatedBuilder(
          animation: _chatService,
          builder: (context, _) {
            if (isWide) {
              return _buildWideLayout(theme, width);
            }
            return _buildMobileLayout(theme);
          },
        ),
      ),
    );
  }

  Widget _buildWideLayout(ThemeData theme, double width) {
    final showTopicsSidebar = width >= 850 && _selectedChat?.isForum == true;

    return Row(
      children: [
        SizedBox(
          width: 290,
          child: _buildChatList(theme),
        ),
        VerticalDivider(width: 1, color: Colors.white.withValues(alpha: 0.08)),
        if (showTopicsSidebar) ...[
          SizedBox(
            width: 210,
            child: _buildTopicsList(theme),
          ),
          VerticalDivider(width: 1, color: Colors.white.withValues(alpha: 0.08)),
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
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: const Color(0xEB0B0F19).withValues(alpha: 0.85),
          elevation: 0,
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
                    ? const Color(0xFF0284C7).withValues(alpha: 0.25)
                    : theme.colorScheme.primaryContainer,
                foregroundColor: _selectedChat?.isForum == true
                    ? const Color(0xFF38BDF8)
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
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            displayTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                          ),
                        ),
                        if (_selectedChat?.isForum == true) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: const Color(0xFF0284C7).withValues(alpha: 0.25),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: const Color(0xFF38BDF8).withValues(alpha: 0.5)),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(_selectedTopic?.iconEmoji ?? '💬', style: const TextStyle(fontSize: 10)),
                                const SizedBox(width: 3),
                                Text(
                                  _selectedTopic?.title ?? 'Общий',
                                  style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: Color(0xFF38BDF8)),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                    if (_selectedChat != null)
                      _buildChatSubtitle(theme, _selectedChat!),
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
            IconButton(
              icon: const Icon(Icons.tune_outlined),
              tooltip: 'Настройки чата',
              onPressed: _showChatSettingsDialog,
            ),
            if (_selectedChat?.kind != 'direct')
              IconButton(
                icon: const Icon(Icons.people_outline_rounded),
                tooltip: 'Участники и права',
                onPressed: () => _showMembersDialog(context),
              ),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Удалить диалог',
              onPressed: _confirmDeleteChat,
            ),
            if (_selectedChat?.isForum == true)
              IconButton(
                icon: const Icon(Icons.forum_outlined),
                tooltip: 'Темы форума',
                onPressed: () => _showTopicsBottomSheet(theme),
              ),
            if (WindowCaptionControls.isSupported)
              const WindowCaptionControls(),
          ],
        ),
        body: _buildChatArea(theme),
      ),
    );
  }

  Widget _buildCategoryChip(String category, String label, int count) {
    final isSelected = _selectedCategory == category;
    final theme = Theme.of(context);

    return FilterChip(
      selected: isSelected,
      label: Text('$label ($count)'),
      labelStyle: TextStyle(
        fontSize: 12,
        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
        color: isSelected
            ? theme.colorScheme.onPrimaryContainer
            : theme.colorScheme.onSurfaceVariant,
      ),
      backgroundColor: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
      selectedColor: theme.colorScheme.primaryContainer,
      showCheckmark: false,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      visualDensity: VisualDensity.compact,
      onSelected: (_) => setState(() => _selectedCategory = category),
    );
  }

  Widget _buildChatList(ThemeData theme) {
    final chats = _chatService.chats;
    final filteredChats = ChatService.filterChatList(
      chats,
      query: _searchQuery,
      category: _selectedCategory,
    );

    return Scaffold(
      backgroundColor: const Color(0xEB0B0F19).withValues(alpha: 0.75),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: Navigator.of(context).canPop()
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                tooltip: 'Назад',
                onPressed: () => Navigator.of(context).maybePop(),
              )
            : null,
        title: const Text('Диалоги', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
        actions: [
          IconButton(
            icon: const Icon(Icons.add_comment_outlined, size: 20),
            tooltip: 'Новый чат',
            onPressed: () => _showNewChatDialog(context),
          ),
          _buildMyStatusAction(theme),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, size: 20),
            tooltip: 'Ещё',
            onSelected: (val) {
              if (val == 'settings') {
                _showChatSettingsDialog();
              } else if (val == 'refresh') {
                final auth = context.read<AuthState>();
                if (auth.api != null) _chatService.loadChats(auth.api!);
              }
            },
            itemBuilder: (ctx) => [
              const PopupMenuItem(
                value: 'refresh',
                child: Row(
                  children: [
                    Icon(Icons.refresh, size: 18),
                    SizedBox(width: 8),
                    Text('Обновить'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'settings',
                child: Row(
                  children: [
                    Icon(Icons.tune_outlined, size: 18),
                    SizedBox(width: 8),
                    Text('Настройки'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: _chatService.isLoadingChats && chats.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: TextField(
                    controller: _searchController,
                    decoration: InputDecoration(
                      hintText: 'Поиск диалогов...',
                      prefixIcon: const Icon(Icons.search, size: 20),
                      suffixIcon: _searchQuery.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear, size: 18),
                              onPressed: () {
                                _searchController.clear();
                                setState(() => _searchQuery = '');
                              },
                            )
                          : null,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      filled: true,
                      fillColor: const Color(0xFF1E293B).withValues(alpha: 0.6),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                    ),
                    onChanged: (val) => setState(() => _searchQuery = val),
                  ),
                ),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      _buildCategoryChip('all', 'Все', chats.length),
                      const SizedBox(width: 6),
                      _buildCategoryChip(
                        'direct',
                        'Личные',
                        chats.where((c) => c.kind == 'direct').length,
                      ),
                      const SizedBox(width: 6),
                      _buildCategoryChip(
                        'forum',
                        'Форумы',
                        chats.where((c) => c.isForum).length,
                      ),
                      const SizedBox(width: 6),
                      _buildCategoryChip(
                        'unread',
                        'Непрочитанные',
                        chats.where((c) => c.unreadCount > 0).length,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                Expanded(
                  child: filteredChats.isEmpty
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
                                  child: Icon(
                                    _searchQuery.isNotEmpty
                                        ? Icons.search_off_rounded
                                        : Icons.forum_rounded,
                                    size: 32,
                                    color: theme.colorScheme.primary,
                                  ),
                                ),
                                const SizedBox(height: 16),
                                Text(
                                  _searchQuery.isNotEmpty
                                      ? 'Диалоги не найдены'
                                      : 'Корпоративный мессенджер',
                                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  _searchQuery.isNotEmpty
                                      ? 'Попробуйте изменить поисковый запрос или фильтр.'
                                      : 'Общайтесь с коллегами, обсуждайте проекты в тематических форумах и звоните через P2P.',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(fontSize: 13, color: theme.colorScheme.onSurfaceVariant),
                                ),
                                if (_searchQuery.isEmpty) ...[
                                  const SizedBox(height: 20),
                                  FilledButton.icon(
                                    onPressed: () => _showNewChatDialog(context),
                                    icon: const Icon(Icons.person_add_alt_1_outlined),
                                    label: const Text('Написать коллеге'),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        )
                      : ListView.separated(
                          itemCount: filteredChats.length,
                          separatorBuilder: (_, __) => Divider(
                            height: 1,
                            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
                          ),
                          itemBuilder: (context, index) {
                            final chat = filteredChats[index];
                    final isSelected = _selectedChat?.id == chat.id;
                    final displayTitle = _resolveChatTitle(chat);
                    final initials = _getInitials(displayTitle);

                    return ListTile(
                      selected: isSelected,
                      selectedTileColor: theme.colorScheme.primaryContainer.withValues(alpha: 0.2),
                      leading: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          CircleAvatar(
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
                          if (chat.kind == 'direct') ...[
                            Builder(
                              builder: (_) {
                                final peer = chat.peerUserId.isNotEmpty ? chat.peerUserId : chat.title;
                                final p = _chatService.getPresence(peer);
                                return Positioned(
                                  right: -1,
                                  bottom: -1,
                                  child: Container(
                                    width: 10,
                                    height: 10,
                                    decoration: BoxDecoration(
                                      color: p.statusColor,
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: theme.colorScheme.surface,
                                        width: 1.5,
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                          ],
                        ],
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
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (chat.unreadCount > 0)
                            Badge(
                              label: Text('${chat.unreadCount}'),
                              backgroundColor: theme.colorScheme.primary,
                            ),
                          PopupMenuButton<String>(
                            icon: const Icon(Icons.more_vert, size: 18),
                            tooltip: 'Действия',
                            onSelected: (val) {
                              if (val == 'delete') {
                                _confirmDeleteChat(chat);
                              }
                            },
                            itemBuilder: (ctx) => [
                              const PopupMenuItem(
                                value: 'delete',
                                child: Row(
                                  children: [
                                    Icon(Icons.delete_outline, size: 18, color: Colors.red),
                                    SizedBox(width: 8),
                                    Text('Удалить диалог', style: TextStyle(color: Colors.red)),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                      onTap: () => _selectChat(chat),
                      onLongPress: () => _confirmDeleteChat(chat),
                    );
                  },
                ),
              ),
            ],
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
      backgroundColor: const Color(0xEB0B0F19).withValues(alpha: 0.75),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('Темы форума', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
        actions: [
          IconButton(
            icon: const Icon(Icons.add_rounded),
            tooltip: 'Создать тему',
            onPressed: () => _showCreateTopicDialog(context),
          ),
        ],
      ),
      body: ListView.builder(
        itemCount: topics.length,
        itemBuilder: (context, index) {
          final topic = topics[index];
          final isSelected = _selectedTopic?.id == topic.id;
          final auth = context.read<AuthState>();
          final canManage = _canManageTopics(auth);

          String prefix = '';
          if (topic.isPinned) prefix += '📌 ';
          if (topic.isClosed) prefix += '🔒 ';

          return ListTile(
            dense: true,
            selected: isSelected,
            selectedTileColor: const Color(0xFF0284C7).withValues(alpha: 0.25),
            leading: Text(topic.iconEmoji, style: const TextStyle(fontSize: 16)),
            title: Text(
              '$prefix${topic.title}',
              style: TextStyle(
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                fontSize: 13,
                color: isSelected ? const Color(0xFF38BDF8) : null,
              ),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (topic.unreadCount > 0)
                  Badge(
                    label: Text('${topic.unreadCount}'),
                    backgroundColor: const Color(0xFF0284C7),
                  ),
                if (canManage)
                  IconButton(
                    icon: const Icon(Icons.more_vert, size: 16),
                    tooltip: 'Управление темой',
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    onPressed: () => _showEditTopicDialog(context, topic),
                  ),
              ],
            ),
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
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Выберите тему форума', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    TextButton.icon(
                      onPressed: () {
                        Navigator.pop(context);
                        _showCreateTopicDialog(context);
                      },
                      icon: const Icon(Icons.add_rounded, size: 18),
                      label: const Text('Создать'),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: topics.length,
                  itemBuilder: (context, index) {
                    final t = topics[index];
                    final auth = context.read<AuthState>();
                    final canManage = _canManageTopics(auth);
                    String prefix = '';
                    if (t.isPinned) prefix += '📌 ';
                    if (t.isClosed) prefix += '🔒 ';
                    return ListTile(
                      leading: Text(t.iconEmoji),
                      title: Text('$prefix${t.title}'),
                      trailing: canManage
                          ? IconButton(
                              icon: const Icon(Icons.settings_outlined, size: 18),
                              tooltip: 'Управление темой',
                              onPressed: () {
                                Navigator.pop(context);
                                _showEditTopicDialog(context, t);
                              },
                            )
                          : null,
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

  Widget _buildHorizontalTopicsBar(ThemeData theme) {
    if (_selectedChat == null || !_selectedChat!.isForum) return const SizedBox.shrink();
    final topics = _chatService.getTopics(_selectedChat!.id);

    return Container(
      height: 46,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xEB0B0F19).withValues(alpha: 0.65),
        border: Border(
          bottom: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
        ),
      ),
      child: Row(
        children: [
          const Icon(Icons.forum_outlined, size: 16, color: Color(0xFF38BDF8)),
          const SizedBox(width: 8),
          const Text(
            'Темы:',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: Color(0xFF94A3B8),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: topics.length + 1,
              separatorBuilder: (_, __) => const SizedBox(width: 6),
              itemBuilder: (context, index) {
                if (index == topics.length) {
                  return ActionChip(
                    avatar: const Icon(Icons.add, size: 14, color: Color(0xFF38BDF8)),
                    label: const Text('Тема', style: TextStyle(fontSize: 12, color: Color(0xFF38BDF8))),
                    backgroundColor: const Color(0xFF0284C7).withValues(alpha: 0.15),
                    side: BorderSide(color: const Color(0xFF0284C7).withValues(alpha: 0.4)),
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _showCreateTopicDialog(context),
                  );
                }
                final topic = topics[index];
                final isSelected = _selectedTopic?.id == topic.id;
                final auth = context.read<AuthState>();
                final canManage = _canManageTopics(auth);
                String prefix = '';
                if (topic.isPinned) prefix += '📌 ';
                if (topic.isClosed) prefix += '🔒 ';
                return GestureDetector(
                  onSecondaryTap: canManage ? () => _showEditTopicDialog(context, topic) : null,
                  onLongPress: canManage ? () => _showEditTopicDialog(context, topic) : null,
                  child: ChoiceChip(
                    avatar: Text(topic.iconEmoji, style: const TextStyle(fontSize: 13)),
                    label: Text(
                      '$prefix${topic.title}${topic.unreadCount > 0 ? ' (${topic.unreadCount})' : ''}',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                        color: isSelected ? Colors.white : const Color(0xFFCBD5E1),
                      ),
                    ),
                    selected: isSelected,
                    selectedColor: const Color(0xFF0284C7),
                    backgroundColor: const Color(0xFF1E293B).withValues(alpha: 0.7),
                    side: BorderSide(
                      color: isSelected
                          ? const Color(0xFF38BDF8)
                          : Colors.white.withValues(alpha: 0.12),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    visualDensity: VisualDensity.compact,
                    showCheckmark: false,
                    onSelected: (_) => _selectTopic(topic),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChatArea(ThemeData theme) {
    final chatId = _selectedChat?.id ?? '';
    final topicId = _selectedTopic?.id ?? 0;
    final messages = _chatService.getMessages(chatId, topicId);
    final auth = context.read<AuthState>();
    final currentUsername = auth.username;
    final currentDisplayName = auth.displayName;
    final currentUserId = auth.currentUser?['id']?.toString() ?? '';
    final isWide = MediaQuery.of(context).size.width >= 600;

    return Stack(
      children: [
        Column(
          children: [
            if (isWide && _selectedChat != null)
              _buildWideChatHeader(theme),
            if (_selectedChat?.isForum == true)
              _buildHorizontalTopicsBar(theme),
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
                        final isMe = (currentUserId.isNotEmpty && msg.senderId == currentUserId) ||
                            (currentDisplayName.isNotEmpty && msg.senderName == currentDisplayName) ||
                            (currentUsername.isNotEmpty && (msg.senderName == currentUsername || msg.senderId == currentUsername));
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
      child: GestureDetector(
        onLongPress: () => _showMessageContextMenu(theme, msg, isMe),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(
            color: isMe
                ? const Color(0xFF0284C7)
                : const Color(0xFF1E293B).withValues(alpha: 0.85),
            border: Border.all(
              color: isMe
                  ? const Color(0xFF38BDF8).withValues(alpha: 0.3)
                  : Colors.white.withValues(alpha: 0.08),
            ),
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
              if (msg.isForwarded)
                Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Text(
                    '➡️ Переслано от: ${msg.forwardSenderName ?? 'Сотрудник'}',
                    style: TextStyle(
                      fontSize: 11,
                      fontStyle: FontStyle.italic,
                      color: isMe ? Colors.white70 : theme.colorScheme.primary,
                    ),
                  ),
                ),
              if (msg.replyTo != null || msg.replyToId != null)
                Container(
                  margin: const EdgeInsets.only(bottom: 6),
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: isMe
                        ? Colors.white.withValues(alpha: 0.15)
                        : theme.colorScheme.surface.withValues(alpha: 0.7),
                    borderRadius: BorderRadius.circular(6),
                    border: Border(
                      left: BorderSide(
                        color: isMe ? Colors.white : theme.colorScheme.primary,
                        width: 3,
                      ),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        msg.replyTo != null && msg.replyTo!.senderName.isNotEmpty
                            ? msg.replyTo!.senderName
                            : (msg.replyTo?.senderId ?? 'Сообщение'),
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: isMe ? Colors.white : theme.colorScheme.primary,
                        ),
                      ),
                      Text(
                        msg.replyTo != null && msg.replyTo!.body.isNotEmpty
                            ? msg.replyTo!.body
                            : (msg.replyToId != null ? 'Ответ на сообщение #${msg.replyToId}' : 'Вложение'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: isMe ? Colors.white70 : theme.colorScheme.outline,
                        ),
                      ),
                    ],
                  ),
                ),
              if (msg.kind == 'voice' && msg.metadata['waveform'] is String)
                WaveformBubble.fromBase64(
                  base64Waveform: msg.metadata['waveform'] as String,
                )
              else if (msg.body.isNotEmpty && !_isDefaultAttachmentBody(msg))
                Text.rich(
                  TextSpan(
                    children: msg.getSpans(
                      context,
                      onLinkTap: (url) async {
                        final uri = Uri.tryParse(url);
                        if (uri != null && await canLaunchUrl(uri)) {
                          await launchUrl(uri, mode: LaunchMode.externalApplication);
                        }
                      },
                    ),
                    style: TextStyle(
                      fontSize: 14,
                      color: isMe ? Colors.white : theme.colorScheme.onSurface,
                    ),
                  ),
                ),
              if (msg.hasAttachments)
                ...msg.attachments.map((att) => _buildAttachmentItem(theme, att, isMe)),
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
                  if (msg.isEdited) ...[
                    const SizedBox(width: 4),
                    Text(
                      '(изм.)',
                      style: TextStyle(
                        fontSize: 9,
                        fontStyle: FontStyle.italic,
                        color: isMe ? Colors.white70 : theme.colorScheme.outline,
                      ),
                    ),
                  ],
                  if (isMe) ...[
                    const SizedBox(width: 4),
                    const Icon(Icons.done_all, size: 12, color: Colors.white70),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showMessageContextMenu(ThemeData theme, ChatMessage msg, bool isMe) {
    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.reply),
                title: const Text('Ответить'),
                onTap: () {
                  Navigator.pop(ctx);
                  setState(() {
                    _replyingTo = msg;
                    _editingMessage = null;
                  });
                },
              ),
              ListTile(
                leading: const Icon(Icons.forward),
                title: const Text('Переслать'),
                onTap: () {
                  Navigator.pop(ctx);
                  _showForwardDialog(msg);
                },
              ),
              if (isMe && (msg.kind == 'text' || msg.kind == 'file'))
                ListTile(
                  leading: const Icon(Icons.edit_outlined),
                  title: const Text('Редактировать'),
                  onTap: () {
                    Navigator.pop(ctx);
                    setState(() {
                      _editingMessage = msg;
                      _replyingTo = null;
                      _textController.text = msg.body;
                    });
                  },
                ),
              ListTile(
                leading: const Icon(Icons.copy_outlined),
                title: const Text('Копировать текст'),
                onTap: () {
                  Navigator.pop(ctx);
                  Clipboard.setData(ClipboardData(text: msg.body));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Текст скопирован')),
                  );
                },
              ),
              ListTile(
                leading: Icon(Icons.delete_outline, color: theme.colorScheme.error),
                title: Text(
                  'Удалить',
                  style: TextStyle(color: theme.colorScheme.error),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _confirmDeleteMessage(msg, isMe);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _confirmDeleteMessage(ChatMessage msg, bool isMe) async {
    final auth = context.read<AuthState>();
    if (auth.api == null || _selectedChat == null) return;

    final isAdmin = auth.isAdmin;
    final canDeleteEveryone = isMe || isAdmin;
    bool forEveryone = canDeleteEveryone;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Удалить сообщение?'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Выберите вариант удаления:'),
                  const SizedBox(height: 12),
                  if (canDeleteEveryone)
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: forEveryone,
                      title: const Text('Удалить для всех'),
                      subtitle: const Text('Сообщение будет удалено у всех участников чата'),
                      onChanged: (val) {
                        setDialogState(() {
                          forEveryone = val ?? false;
                        });
                      },
                    )
                  else
                    const Text(
                      'Сообщение будет скрыто только у вас.',
                      style: TextStyle(fontSize: 13, color: Colors.grey),
                    ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Отмена'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text(
                    'Удалить',
                    style: TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ),
              ],
            );
          },
        );
      },
    );

    if (confirmed == true && mounted) {
      try {
        await _chatService.deleteMessage(
          auth.api!,
          _selectedChat!.id,
          msg.id,
          topicId: _selectedTopic?.id ?? 0,
          forEveryone: forEveryone,
        );
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Не удалось удалить сообщение')),
          );
        }
      }
    }
  }

  void _showForwardDialog(ChatMessage msg) {
    final auth = context.read<AuthState>();
    if (auth.api == null) return;

    showDialog<void>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Переслать сообщение в...'),
          content: SizedBox(
            width: double.maxFinite,
            height: 300,
            child: ListView.builder(
              itemCount: _chatService.chats.length,
              itemBuilder: (context, i) {
                final chat = _chatService.chats[i];
                final title = _resolveChatTitle(chat);
                return ListTile(
                  leading: CircleAvatar(
                    child: Text(title.isNotEmpty ? title[0].toUpperCase() : '?'),
                  ),
                  title: Text(title),
                  subtitle: Text(chat.isForum ? '🏛️ Форум' : (chat.kind == 'direct' ? 'Личный диалог' : 'Группа')),
                  onTap: () async {
                    final messenger = ScaffoldMessenger.of(context);
                    Navigator.pop(ctx);
                    try {
                      await _chatService.forwardMessage(
                        auth.api!,
                        chat.id,
                        targetTopicId: 0,
                        originalMessage: msg,
                      );
                      if (mounted) {
                        messenger.showSnackBar(
                          SnackBar(content: Text('Переслано в "$title"')),
                        );
                      }
                    } catch (e) {
                      if (mounted) {
                        messenger.showSnackBar(
                          const SnackBar(content: Text('Ошибка пересылки сообщения')),
                        );
                      }
                    }
                  },
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Отмена'),
            ),
          ],
        );
      },
    );
  }

  bool _isUuid(String s) {
    return RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$').hasMatch(s.trim());
  }

  String _resolveChatTitle(ChatItem chat) {
    final title = chat.title.trim();
    for (final c in _chatService.contacts) {
      if (c.id == title || c.username.toLowerCase() == title.toLowerCase()) {
        return c.displayName.isNotEmpty ? c.displayName : c.username;
      }
    }
    if (_isUuid(title)) {
      return 'Диалог с сотрудником';
    }
    return title.isNotEmpty ? title : 'Диалог';
  }

  String _resolveSenderName(ChatMessage msg) {
    for (final c in _chatService.contacts) {
      if ((c.id.isNotEmpty && c.id == msg.senderId) ||
          (c.username.isNotEmpty && (c.username.toLowerCase() == msg.senderId.toLowerCase() || c.username.toLowerCase() == msg.senderName.toLowerCase())) ||
          (c.displayName.isNotEmpty && c.displayName == msg.senderName)) {
        return c.displayName.isNotEmpty ? c.displayName : c.username;
      }
    }
    if (msg.senderName.isNotEmpty && !_isUuid(msg.senderName)) {
      return msg.senderName;
    }
    return msg.senderName.isNotEmpty ? msg.senderName : (msg.senderId.isNotEmpty ? msg.senderId : 'Сотрудник');
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
    final auth = context.read<AuthState>();
    final isTopicClosed = _selectedTopic?.isClosed == true;
    final isManager = _canManageTopics(auth);

    if (isTopicClosed && !isManager) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: const Color(0xEB0B0F19).withValues(alpha: 0.85),
          border: Border(top: BorderSide(color: Colors.white.withValues(alpha: 0.08))),
        ),
        child: SafeArea(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: theme.colorScheme.errorContainer.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: theme.colorScheme.error.withValues(alpha: 0.3)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.lock_outline_rounded, size: 18, color: theme.colorScheme.error),
                const SizedBox(width: 8),
                Text(
                  'Тема закрыта для новых сообщений',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.error,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xEB0B0F19).withValues(alpha: 0.85),
        border: Border(top: BorderSide(color: Colors.white.withValues(alpha: 0.08))),
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isTopicClosed)
              Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.amber.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                  border: const Border(left: BorderSide(color: Colors.amber, width: 3)),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.lock_outline_rounded, size: 16, color: Colors.amber),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Тема закрыта (вы можете писать как администратор/модератор)',
                        style: TextStyle(fontSize: 12, color: Colors.amber, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
              ),
            if (_editingMessage != null)
              Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E293B).withValues(alpha: 0.8),
                  borderRadius: BorderRadius.circular(10),
                  border: const Border(
                    left: BorderSide(color: Colors.amber, width: 3),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.edit, size: 16, color: Colors.amber),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text(
                            'Редактирование сообщения',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: Colors.amber,
                            ),
                          ),
                          Text(
                            _editingMessage!.body,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      tooltip: 'Отменить редактирование',
                      onPressed: () {
                        setState(() {
                          _editingMessage = null;
                          _textController.clear();
                        });
                      },
                    ),
                  ],
                ),
              )
            else if (_replyingTo != null)
              Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E293B).withValues(alpha: 0.8),
                  borderRadius: BorderRadius.circular(10),
                  border: const Border(
                    left: BorderSide(color: Color(0xFF38BDF8), width: 3),
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _resolveSenderName(_replyingTo!),
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: theme.colorScheme.primary,
                            ),
                          ),
                          Text(
                            _replyingTo!.body,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      tooltip: 'Отменить ответ (Esc)',
                      onPressed: () => setState(() => _replyingTo = null),
                    ),
                  ],
                ),
              ),
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
                  child: CallbackShortcuts(
                    bindings: {
                      const SingleActivator(LogicalKeyboardKey.enter): _handleSend,
                      const SingleActivator(LogicalKeyboardKey.escape): () {
                        if (_replyingTo != null) {
                          setState(() => _replyingTo = null);
                        }
                      },
                    },
                    child: TextField(
                      controller: _textController,
                      maxLines: 4,
                      minLines: 1,
                      textInputAction: TextInputAction.newline,
                      decoration: InputDecoration(
                        hintText: _selectedTopic != null
                            ? 'Сообщение в ${_selectedTopic!.title}...'
                            : 'Напишите сообщение...',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: BorderSide.none,
                        ),
                        filled: true,
                        fillColor: const Color(0xFF1E293B).withValues(alpha: 0.7),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  icon: const Icon(Icons.send),
                  tooltip: 'Отправить (Enter)',
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
        color: const Color(0xEB0B0F19).withValues(alpha: 0.85),
        border: Border(bottom: BorderSide(color: Colors.white.withValues(alpha: 0.08))),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 19,
            backgroundColor: _selectedChat!.isForum
                ? const Color(0xFF0284C7).withValues(alpha: 0.25)
                : const Color(0xFF38BDF8).withValues(alpha: 0.25),
            foregroundColor: const Color(0xFF38BDF8),
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
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        chatTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                    ),
                    if (_selectedChat!.isForum) ...[
                      const SizedBox(width: 8),
                      InkWell(
                        onTap: (_canManageTopics(context.read<AuthState>()) && _selectedTopic != null)
                            ? () => _showEditTopicDialog(context, _selectedTopic!)
                            : null,
                        borderRadius: BorderRadius.circular(10),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: const Color(0xFF0284C7).withValues(alpha: 0.25),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: const Color(0xFF38BDF8).withValues(alpha: 0.5)),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (_selectedTopic?.isPinned == true) ...[
                                const Text('📌', style: TextStyle(fontSize: 10)),
                                const SizedBox(width: 3),
                              ],
                              if (_selectedTopic?.isClosed == true) ...[
                                const Text('🔒', style: TextStyle(fontSize: 10)),
                                const SizedBox(width: 3),
                              ],
                              Text(_selectedTopic?.iconEmoji ?? '💬', style: const TextStyle(fontSize: 11)),
                              const SizedBox(width: 4),
                              Text(
                                _selectedTopic?.title ?? 'Общий',
                                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFF38BDF8)),
                              ),
                              if (_canManageTopics(context.read<AuthState>()) && _selectedTopic != null) ...[
                                const SizedBox(width: 4),
                                const Icon(Icons.settings_outlined, size: 12, color: Color(0xFF38BDF8)),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                _buildChatSubtitle(theme, _selectedChat!),
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
            icon: const Icon(Icons.settings_voice_outlined),
            tooltip: 'Настройки звонков',
            onPressed: _showMediaSettingsDialog,
          ),
          IconButton(
            icon: const Icon(Icons.tune_outlined),
            tooltip: 'Настройки чата',
            onPressed: _showChatSettingsDialog,
          ),
          if (_selectedChat?.kind != 'direct')
            IconButton(
              icon: const Icon(Icons.people_outline_rounded),
              tooltip: 'Участники и права',
              onPressed: () => _showMembersDialog(context),
            ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Удалить диалог',
            onPressed: _confirmDeleteChat,
          ),
          if (WindowCaptionControls.isSupported)
            const WindowCaptionControls(),
        ],
      ),
    );
  }

  bool _isDefaultAttachmentBody(ChatMessage msg) {
    if (!msg.hasAttachments) return false;
    final body = msg.body.trim();
    for (final att in msg.attachments) {
      final name = (att['name'] ?? att['file_name'] ?? '').toString().trim();
      if (name.isEmpty) continue;
      if (body == name ||
          body == '📷 $name' ||
          body == '📎 $name' ||
          body == '🎥 $name' ||
          body == '📹 $name' ||
          body == '▶️ $name' ||
          body == 'Вложение' ||
          body == 'Видео') {
        return true;
      }
    }
    return false;
  }

  bool _isImageAttachment(Map<String, dynamic> att) {
    final contentType = (att['content_type'] ?? att['contentType'] ?? '').toString().toLowerCase();
    if (contentType.startsWith('image/')) return true;
    final name = (att['name'] ?? att['file_name'] ?? '').toString().toLowerCase();
    return name.endsWith('.png') ||
        name.endsWith('.jpg') ||
        name.endsWith('.jpeg') ||
        name.endsWith('.webp') ||
        name.endsWith('.gif') ||
        name.endsWith('.bmp') ||
        name.endsWith('.heic') ||
        name.endsWith('.heif') ||
        name.endsWith('.ico');
  }

  bool _isVideoAttachment(Map<String, dynamic> att) {
    final contentType = (att['content_type'] ?? att['contentType'] ?? '').toString().toLowerCase();
    if (contentType.startsWith('video/')) return true;
    final name = (att['name'] ?? att['file_name'] ?? '').toString().toLowerCase();
    return name.endsWith('.mp4') ||
        name.endsWith('.mov') ||
        name.endsWith('.webm') ||
        name.endsWith('.mkv') ||
        name.endsWith('.avi') ||
        name.endsWith('.m4v') ||
        name.endsWith('.3gp') ||
        name.endsWith('.ts');
  }

  IconData _getFileIcon(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.pdf')) return Icons.picture_as_pdf_outlined;
    if (lower.endsWith('.mp3') || lower.endsWith('.wav') || lower.endsWith('.m4a') || lower.endsWith('.ogg')) {
      return Icons.audiotrack_outlined;
    }
    if (lower.endsWith('.mp4') || lower.endsWith('.mov') || lower.endsWith('.avi') || lower.endsWith('.mkv')) {
      return Icons.video_file_outlined;
    }
    if (lower.endsWith('.zip') || lower.endsWith('.rar') || lower.endsWith('.7z') || lower.endsWith('.tar') || lower.endsWith('.gz')) {
      return Icons.folder_zip_outlined;
    }
    if (lower.endsWith('.doc') || lower.endsWith('.docx') || lower.endsWith('.txt') || lower.endsWith('.rtf') || lower.endsWith('.md')) {
      return Icons.description_outlined;
    }
    if (lower.endsWith('.xls') || lower.endsWith('.xlsx') || lower.endsWith('.csv')) {
      return Icons.table_chart_outlined;
    }
    if (lower.endsWith('.ppt') || lower.endsWith('.pptx')) {
      return Icons.slideshow_outlined;
    }
    return Icons.insert_drive_file_outlined;
  }

  Future<File?> _ensureAttachmentCached(
    ApiClient api,
    String attId,
    String fileName, {
    List<int>? initialBytes,
  }) async {
    if (attId.isEmpty) return null;
    try {
      final tempDir = await getTemporaryDirectory();
      final cacheDir = Directory('${tempDir.path}/ligament_chat_cache');
      if (!await cacheDir.exists()) {
        await cacheDir.create(recursive: true);
      }
      final safeName = fileName.replaceAll(RegExp(r'[^\w\.\-\(\) ]'), '_');
      final targetFile = File('${cacheDir.path}/${attId}_$safeName');
      if (await targetFile.exists() && await targetFile.length() > 0) {
        return targetFile;
      }
      final List<int> bytes;
      if (initialBytes != null && initialBytes.isNotEmpty) {
        bytes = initialBytes;
      } else {
        bytes = await api.downloadChatAttachment(attId);
      }
      await targetFile.writeAsBytes(bytes, flush: true);
      return targetFile;
    } catch (e) {
      return null;
    }
  }

  Future<void> _previewAttachmentNatively(String attId, String fileName) async {
    final auth = context.read<AuthState>();
    if (auth.api == null || attId.isEmpty) return;

    if (mounted) {
      setState(() => _downloadingPreviews.add(attId));
    }

    try {
      final file = await _ensureAttachmentCached(auth.api!, attId, fileName);
      if (file == null || !await file.exists()) {
        throw Exception('Не удалось загрузить файл');
      }

      final result = await OpenFilex.open(file.path);
      if (result.type != ResultType.done && mounted) {
        if (result.type == ResultType.noAppToOpen) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Нет приложения для открытия данного типа файла')),
          );
        } else if (result.type == ResultType.permissionDenied) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Отказано в доступе к файлу')),
          );
        } else if (result.type == ResultType.fileNotFound) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Файл не найден на устройстве')),
          );
        } else if (result.message.isNotEmpty && result.message != 'done') {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Ошибка открытия: ${result.message}')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Ошибка предпросмотра: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _downloadingPreviews.remove(attId));
      }
    }
  }

  Widget _buildAttachmentItem(ThemeData theme, Map<String, dynamic> att, bool isMe) {
    final auth = context.read<AuthState>();
    if (_isImageAttachment(att)) {
      return _ChatImageAttachmentPreview(
        attachment: att,
        isMe: isMe,
        apiClient: auth.api,
        ensureCached: (attId, name, {initialBytes}) =>
            _ensureAttachmentCached(auth.api!, attId, name, initialBytes: initialBytes),
        onPreview: (attId, name) => _previewAttachmentNatively(attId, name),
        onSave: (attId, name) => _downloadAndSaveFile(attId, name),
      );
    }
    if (_isVideoAttachment(att)) {
      return _ChatVideoAttachmentPreview(
        attachment: att,
        isMe: isMe,
        apiClient: auth.api,
        ensureCached: (attId, name, {initialBytes}) =>
            _ensureAttachmentCached(auth.api!, attId, name, initialBytes: initialBytes),
        onPreview: (attId, name) => _previewAttachmentNatively(attId, name),
        onSave: (attId, name) => _downloadAndSaveFile(attId, name),
      );
    }
    return _buildFileAttachmentCard(theme, att, isMe);
  }

  Widget _buildFileAttachmentCard(ThemeData theme, Map<String, dynamic> att, bool isMe) {
    final name = att['name']?.toString() ?? att['file_name']?.toString() ?? 'Файл';
    final sizeBytes = (att['size'] as num?)?.toInt() ?? (att['file_size'] as num?)?.toInt() ?? 0;
    final attId = att['id']?.toString() ?? att['attachment_id']?.toString() ?? '';
    final sizeStr = sizeBytes > 1024 * 1024
        ? '${(sizeBytes / (1024 * 1024)).toStringAsFixed(1)} МБ'
        : '${(sizeBytes / 1024).toStringAsFixed(1)} КБ';
    final isDownloading = _downloadingPreviews.contains(attId);

    return Container(
      margin: const EdgeInsets.only(top: 6),
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
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => _previewAttachmentNatively(attId, name),
          child: Padding(
            padding: const EdgeInsets.all(8),
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
                    _getFileIcon(name),
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
                        '$sizeStr • Просмотр',
                        style: TextStyle(
                          fontSize: 11,
                          color: isMe ? Colors.white70 : theme.colorScheme.outline,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                if (isDownloading)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: isMe ? Colors.white : theme.colorScheme.primary,
                      ),
                    ),
                  )
                else ...[
                  IconButton(
                    icon: Icon(
                      Icons.visibility_outlined,
                      size: 20,
                      color: isMe ? Colors.white : theme.colorScheme.primary,
                    ),
                    tooltip: 'Просмотр нативно',
                    onPressed: () => _previewAttachmentNatively(attId, name),
                  ),
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
              ],
            ),
          ),
        ),
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
      var bytes = file.bytes;
      if ((bytes == null || bytes.isEmpty) && file.path != null && file.path!.isNotEmpty) {
        try {
          bytes = await File(file.path!).readAsBytes();
        } catch (_) {}
      }
      if (bytes == null || bytes.isEmpty) return;

      setState(() => _isUploading = true);
      final attId = await _chatService.sendAttachment(
        auth.api!,
        _selectedChat!.id,
        topicId: _selectedTopic?.id ?? 0,
        fileName: file.name,
        bytes: bytes,
      );
      if (attId.isNotEmpty) {
        unawaited(_ensureAttachmentCached(auth.api!, attId, file.name, initialBytes: bytes));
      }
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
      final cached = await _ensureAttachmentCached(auth.api!, attId, fileName);
      final Uint8List bytes;
      if (cached != null && await cached.exists()) {
        bytes = await cached.readAsBytes();
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Скачивание файла...'), duration: Duration(seconds: 1)),
          );
        }
        bytes = await auth.api!.downloadChatAttachment(attId);
      }
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

  Future<void> _showChatSettingsDialog() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Row(
                children: [
                  Icon(Icons.tune_outlined),
                  SizedBox(width: 8),
                  Text('Настройки чата'),
                ],
              ),
              content: SizedBox(
                width: 380,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SwitchListTile(
                      title: const Text('Звуковые оповещения'),
                      subtitle: const Text('Воспроизводить звук при входящих сообщениях'),
                      value: _chatService.playSounds,
                      onChanged: (val) async {
                        await _chatService.setPlaySounds(val);
                        setDialogState(() {});
                      },
                    ),
                    SwitchListTile(
                      title: const Text('Всплывающие уведомления'),
                      subtitle: const Text('Системные уведомления о новых сообщениях'),
                      value: _chatService.showNotifications,
                      onChanged: (val) async {
                        await _chatService.setShowNotifications(val);
                        setDialogState(() {});
                      },
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Закрыть'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _confirmDeleteChat([ChatItem? targetChat]) async {
    final chat = targetChat ?? _selectedChat;
    if (chat == null) return;
    final chatTitle = _resolveChatTitle(chat);
    final auth = context.read<AuthState>();
    final api = auth.api;
    if (api == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.delete_outline, color: Colors.red),
            SizedBox(width: 8),
            Text('Удалить диалог?'),
          ],
        ),
        content: Text(
          'Вы уверены, что хотите удалить диалог с «$chatTitle»? Все сообщения и история переписки будут удалены навсегда.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      try {
        await _chatService.deleteChat(api, chat.id);
        if (_selectedChat?.id == chat.id) {
          setState(() {
            _selectedChat = null;
          });
        }
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Диалог успешно удален')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Ошибка удаления диалога: $e'),
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
          );
        }
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
    final auth = context.read<AuthState>();
    final targetUser = _selectedChat!.peerUserId.isNotEmpty
        ? _selectedChat!.peerUserId
        : _selectedChat!.title;

    CallSessionManager.instance.startCall(
      chatId: _selectedChat!.id,
      chatTitle: chatTitle,
      targetUserId: targetUser,
      isVideo: isVideo,
      iceServers: auth.iceServers,
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
  final ApiClient api;
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

                                  final p = ChatService.instance.getPresence(c.username);
                                  return ListTile(
                                    leading: Stack(
                                      clipBehavior: Clip.none,
                                      children: [
                                        CircleAvatar(
                                          backgroundColor: theme.colorScheme.primaryContainer,
                                          foregroundColor: theme.colorScheme.onPrimaryContainer,
                                          child: Text(letter),
                                        ),
                                        Positioned(
                                          right: -1,
                                          bottom: -1,
                                          child: Container(
                                            width: 10,
                                            height: 10,
                                            decoration: BoxDecoration(
                                              color: p.statusColor,
                                              shape: BoxShape.circle,
                                              border: Border.all(
                                                color: theme.colorScheme.surface,
                                                width: 1.5,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    title: Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            c.displayName.isNotEmpty ? c.displayName : c.username,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(fontWeight: FontWeight.w600),
                                          ),
                                        ),
                                        Text(
                                          p.statusLabel,
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: p.statusColor,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                      ],
                                    ),
                                    subtitle: Text(
                                      p.statusText.isNotEmpty
                                          ? '${p.statusText} · ${c.title.isNotEmpty ? c.title : (c.email.isNotEmpty ? c.email : '@${c.username}')}'
                                          : (c.title.isNotEmpty ? c.title : (c.email.isNotEmpty ? c.email : '@${c.username}')),
                                      style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
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

class _CreateTopicSheet extends StatefulWidget {
  final ApiClient api;
  final String chatId;
  final ValueChanged<TopicItem> onTopicCreated;

  const _CreateTopicSheet({
    required this.api,
    required this.chatId,
    required this.onTopicCreated,
  });

  @override
  State<_CreateTopicSheet> createState() => _CreateTopicSheetState();
}

class _CreateTopicSheetState extends State<_CreateTopicSheet> {
  final _titleController = TextEditingController();
  String _selectedEmoji = '💬';
  bool _isLoading = false;

  final _emojis = const ['💬', '🚀', '💡', '📢', '⚙️', '📁', '🛠️', '📌'];

  @override
  void dispose() {
    _titleController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final title = _titleController.text.trim();
    if (title.isEmpty) return;

    setState(() => _isLoading = true);
    try {
      final topic = await ChatService.instance.createTopic(
        widget.api,
        widget.chatId,
        title: title,
        iconEmoji: _selectedEmoji,
      );
      widget.onTopicCreated(topic);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Ошибка создания темы: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
        height: 340,
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  '➕ Новая тема форума',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _titleController,
              autofocus: true,
              decoration: InputDecoration(
                labelText: 'Название темы *',
                hintText: 'Например: Обсуждение релизов',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 16),
            const Text(
              'Иконка темы:',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: _emojis.map((emoji) {
                final isSelected = _selectedEmoji == emoji;
                return ChoiceChip(
                  label: Text(emoji, style: const TextStyle(fontSize: 18)),
                  selected: isSelected,
                  onSelected: (selected) {
                    if (selected) setState(() => _selectedEmoji = emoji);
                  },
                );
              }).toList(),
            ),
            const Spacer(),
            FilledButton(
              onPressed: _isLoading ? null : _submit,
              child: _isLoading
                  ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Создать тему'),
            ),
          ],
        ),
      ),
    );
  }
}

class _EditTopicSheet extends StatefulWidget {
  final ApiClient api;
  final String chatId;
  final TopicItem topic;
  final bool isManager;
  final ValueChanged<TopicItem> onTopicUpdated;
  final VoidCallback onTopicDeleted;

  const _EditTopicSheet({
    required this.api,
    required this.chatId,
    required this.topic,
    required this.isManager,
    required this.onTopicUpdated,
    required this.onTopicDeleted,
  });

  @override
  State<_EditTopicSheet> createState() => _EditTopicSheetState();
}

class _EditTopicSheetState extends State<_EditTopicSheet> {
  late final TextEditingController _titleController;
  late String _selectedEmoji;
  late bool _isPinned;
  late bool _isClosed;
  bool _isLoading = false;

  final _emojis = const ['💬', '🚀', '💡', '📢', '⚙️', '📁', '🛠️', '📌', '🔒', '❓', '🎯'];

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.topic.title);
    _selectedEmoji = widget.topic.iconEmoji;
    _isPinned = widget.topic.isPinned;
    _isClosed = widget.topic.isClosed;
  }

  @override
  void dispose() {
    _titleController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final title = _titleController.text.trim();
    if (title.isEmpty) return;

    setState(() => _isLoading = true);
    try {
      final updated = await ChatService.instance.updateTopic(
        widget.api,
        widget.chatId,
        widget.topic.id,
        title: title,
        iconEmoji: _selectedEmoji,
        isPinned: widget.isManager ? _isPinned : null,
        isClosed: widget.isManager ? _isClosed : null,
      );
      widget.onTopicUpdated(updated);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Ошибка обновления темы: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _confirmDelete() async {
    if (widget.topic.isGeneral) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить тему?'),
        content: Text('Тема «${widget.topic.title}» и все сообщения в ней будут удалены.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() => _isLoading = true);
    try {
      await ChatService.instance.deleteTopic(
        widget.api,
        widget.chatId,
        widget.topic.id,
      );
      widget.onTopicDeleted();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Ошибка удаления темы: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SingleChildScrollView(
        child: Container(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    '⚙️ Управление темой',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _titleController,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: 'Название темы *',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 16),
              const Text(
                'Иконка темы:',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: _emojis.map((emoji) {
                  final isSelected = _selectedEmoji == emoji;
                  return ChoiceChip(
                    label: Text(emoji, style: const TextStyle(fontSize: 18)),
                    selected: isSelected,
                    onSelected: (selected) {
                      if (selected) setState(() => _selectedEmoji = emoji);
                    },
                  );
                }).toList(),
              ),
              if (widget.isManager) ...[
                const SizedBox(height: 16),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Закрепить тему вверху', style: TextStyle(fontSize: 14)),
                  secondary: const Text('📌', style: TextStyle(fontSize: 18)),
                  value: _isPinned,
                  onChanged: (val) => setState(() => _isPinned = val),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Закрыть тему (только чтение)', style: TextStyle(fontSize: 14)),
                  secondary: const Text('🔒', style: TextStyle(fontSize: 18)),
                  value: _isClosed,
                  onChanged: (val) => setState(() => _isClosed = val),
                ),
              ],
              const SizedBox(height: 20),
              Row(
                children: [
                  if (widget.isManager && !widget.topic.isGeneral)
                    TextButton.icon(
                      style: TextButton.styleFrom(
                        foregroundColor: theme.colorScheme.error,
                      ),
                      onPressed: _isLoading ? null : _confirmDelete,
                      icon: const Icon(Icons.delete_outline, size: 18),
                      label: const Text('Удалить'),
                    ),
                  const Spacer(),
                  FilledButton(
                    onPressed: _isLoading ? null : _submit,
                    child: _isLoading
                        ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('Сохранить'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChatMembersSheet extends StatefulWidget {
  final ApiClient api;
  final ChatItem chat;

  const _ChatMembersSheet({
    required this.api,
    required this.chat,
  });

  @override
  State<_ChatMembersSheet> createState() => _ChatMembersSheetState();
}

class _ChatMembersSheetState extends State<_ChatMembersSheet> {
  bool _isLoading = true;
  List<Map<String, dynamic>> _members = [];
  List<Map<String, dynamic>> _contacts = [];
  String? _selectedContactUser;
  String _selectedRole = 'member';

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    try {
      final members = await widget.api.getChatMembers(widget.chat.id);
      final contacts = await widget.api.getChatContacts();
      if (mounted) {
        setState(() {
          _members = members;
          _contacts = contacts;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Ошибка загрузки участников: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    }
  }

  Future<void> _addMember() async {
    if (_selectedContactUser == null || _selectedContactUser!.isEmpty) return;

    try {
      await widget.api.addChatMember(
        widget.chat.id,
        userId: _selectedContactUser!,
        role: _selectedRole,
      );
      setState(() => _selectedContactUser = null);
      await _loadData();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Ошибка добавления: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    }
  }

  Future<void> _updateRole(String userId, String newRole) async {
    try {
      await widget.api.updateChatMemberRole(
        widget.chat.id,
        userId: userId,
        role: newRole,
      );
      await _loadData();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Ошибка обновления роли: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    }
  }

  Future<void> _removeMember(String userId) async {
    try {
      await widget.api.removeChatMember(widget.chat.id, userId);
      await _loadData();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Ошибка удаления: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Фильтруем контакты, которые еще не добавлены
    final existingUserIds = _members.map((m) => (m['user_id'] as String? ?? '')).toSet();
    final availableContacts = _contacts.where((c) => !existingUserIds.contains(c['username'] as String? ?? '')).toList();

    return Container(
      height: 520,
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '👥 Участники и права (${_members.length})',
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
              ),
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // Добавление участника
          Row(
            children: [
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: theme.colorScheme.outlineVariant),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: _selectedContactUser,
                      isDense: true,
                      isExpanded: true,
                      hint: const Text('Сотрудник...', style: TextStyle(fontSize: 13)),
                      items: availableContacts.map((c) {
                        final uname = c['username'] as String? ?? '';
                        final dname = c['display_name'] as String? ?? uname;
                        return DropdownMenuItem<String>(
                          value: uname,
                          child: Text(dname, style: const TextStyle(fontSize: 13)),
                        );
                      }).toList(),
                      onChanged: (v) => setState(() => _selectedContactUser = v),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              DropdownButton<String>(
                value: _selectedRole,
                items: const [
                  DropdownMenuItem(value: 'member', child: Text('Участник', style: TextStyle(fontSize: 13))),
                  DropdownMenuItem(value: 'moderator', child: Text('Модератор', style: TextStyle(fontSize: 13))),
                  DropdownMenuItem(value: 'read_only', child: Text('Только чтение', style: TextStyle(fontSize: 13))),
                  DropdownMenuItem(value: 'admin', child: Text('Админ', style: TextStyle(fontSize: 13))),
                ],
                onChanged: (v) {
                  if (v != null) setState(() => _selectedRole = v);
                },
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _selectedContactUser != null ? _addMember : null,
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                ),
                child: const Text('+ Добавить'),
              ),
            ],
          ),
          const Divider(height: 24),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _members.isEmpty
                    ? Center(
                        child: Text(
                          'Нет участников',
                          style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                        ),
                      )
                    : ListView.separated(
                        itemCount: _members.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (ctx, i) {
                          final m = _members[i];
                          final uid = m['user_id'] as String? ?? '';
                          final role = m['role'] as String? ?? 'member';
                          final letter = uid.isNotEmpty ? uid[0].toUpperCase() : '?';

                          return ListTile(
                            dense: true,
                            leading: CircleAvatar(
                              radius: 16,
                              backgroundColor: theme.colorScheme.primaryContainer,
                              foregroundColor: theme.colorScheme.onPrimaryContainer,
                              child: Text(letter, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                            ),
                            title: Text(uid, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                DropdownButton<String>(
                                  value: role,
                                  underline: const SizedBox.shrink(),
                                  items: const [
                                    DropdownMenuItem(value: 'admin', child: Text('Админ', style: TextStyle(fontSize: 12))),
                                    DropdownMenuItem(value: 'moderator', child: Text('Модератор', style: TextStyle(fontSize: 12))),
                                    DropdownMenuItem(value: 'member', child: Text('Участник', style: TextStyle(fontSize: 12))),
                                    DropdownMenuItem(value: 'read_only', child: Text('Только чтение', style: TextStyle(fontSize: 12))),
                                  ],
                                  onChanged: (newRole) {
                                    if (newRole != null && newRole != role) {
                                      _updateRole(uid, newRole);
                                    }
                                  },
                                ),
                                IconButton(
                                  icon: Icon(Icons.delete_outline, size: 18, color: theme.colorScheme.error),
                                  tooltip: 'Удалить участника',
                                  onPressed: () => _removeMember(uid),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}

class _PresenceStatusSheet extends StatefulWidget {
  final ApiClient api;
  final String initialStatus;
  final String initialStatusText;
  final Future<void> Function(String status, String statusText) onStatusChanged;

  const _PresenceStatusSheet({
    required this.api,
    required this.initialStatus,
    required this.initialStatusText,
    required this.onStatusChanged,
  });

  @override
  State<_PresenceStatusSheet> createState() => _PresenceStatusSheetState();
}

class _PresenceStatusSheetState extends State<_PresenceStatusSheet> {
  late String _selectedStatus;
  late final TextEditingController _textController;
  bool _isLoading = false;

  static const List<Map<String, String>> _statusOptions = [
    {
      'id': 'online',
      'label': 'В сети',
      'emoji': '🟢',
      'desc': 'Обычный статус, активен при открытом чате',
    },
    {
      'id': 'busy',
      'label': 'Занят',
      'emoji': '🔴',
      'desc': 'Не беспокоить звонками и сообщениями',
    },
    {
      'id': 'vacation',
      'label': 'В отпуске',
      'emoji': '🏖️',
      'desc': 'Отображается постоянно, даже если чат закрыт',
    },
    {
      'id': 'away',
      'label': 'Отошёл',
      'emoji': '🟡',
      'desc': 'Временное отсутствие на рабочем месте',
    },
    {
      'id': 'dnd',
      'label': 'Не беспокоить',
      'emoji': '⛔',
      'desc': 'Фокусировка на срочной задаче',
    },
  ];

  @override
  void initState() {
    super.initState();
    _selectedStatus = widget.initialStatus.isNotEmpty ? widget.initialStatus : 'online';
    _textController = TextEditingController(text: widget.initialStatusText);
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _isLoading = true);
    try {
      await widget.onStatusChanged(_selectedStatus, _textController.text.trim());
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
        left: 16,
        right: 16,
        top: 16,
      ),
      child: SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Text(
                    'Статус в корпоративном чате',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                '«В сети» означает только открытый чат. Статусы видны коллегам в списке диалогов и контактов.',
                style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 12),
              ..._statusOptions.map((opt) {
                final isSelected = _selectedStatus == opt['id'];
                return Container(
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  decoration: BoxDecoration(
                    color: isSelected
                        ? theme.colorScheme.primaryContainer.withValues(alpha: 0.3)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: isSelected
                          ? theme.colorScheme.primary
                          : theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
                    ),
                  ),
                  child: ListTile(
                    dense: true,
                    leading: Text(opt['emoji']!, style: const TextStyle(fontSize: 20)),
                    title: Text(
                      opt['label']!,
                      style: TextStyle(
                        fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                        color: theme.colorScheme.onSurface,
                      ),
                    ),
                    subtitle: Text(
                      opt['desc']!,
                      style: TextStyle(fontSize: 11, color: theme.colorScheme.onSurfaceVariant),
                    ),
                    trailing: isSelected
                        ? Icon(Icons.check_circle, color: theme.colorScheme.primary, size: 20)
                        : null,
                    onTap: () => setState(() => _selectedStatus = opt['id']!),
                  ),
                );
              }),
              const SizedBox(height: 12),
              TextField(
                controller: _textController,
                decoration: InputDecoration(
                  labelText: 'Комментарий к статусу',
                  hintText: 'например: до 15 ноября, на встрече...',
                  isDense: true,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  prefixIcon: const Icon(Icons.edit_note_outlined),
                ),
                maxLength: 100,
              ),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: _isLoading ? null : _save,
                child: _isLoading
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Сохранить статус'),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChatImageAttachmentPreview extends StatefulWidget {
  final Map<String, dynamic> attachment;
  final bool isMe;
  final ApiClient? apiClient;
  final Future<File?> Function(String attId, String fileName, {List<int>? initialBytes}) ensureCached;
  final void Function(String attId, String fileName) onPreview;
  final void Function(String attId, String fileName) onSave;

  const _ChatImageAttachmentPreview({
    required this.attachment,
    required this.isMe,
    required this.apiClient,
    required this.ensureCached,
    required this.onPreview,
    required this.onSave,
  });

  @override
  State<_ChatImageAttachmentPreview> createState() => _ChatImageAttachmentPreviewState();
}

class _ChatImageAttachmentPreviewState extends State<_ChatImageAttachmentPreview> {
  File? _file;
  bool _isLoading = true;
  bool _hasError = false;

  @override
  void initState() {
    super.initState();
    _loadFile();
  }

  @override
  void didUpdateWidget(covariant _ChatImageAttachmentPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldId = (oldWidget.attachment['id'] ?? oldWidget.attachment['attachment_id'] ?? '').toString();
    final newId = (widget.attachment['id'] ?? widget.attachment['attachment_id'] ?? '').toString();
    if (oldId != newId) {
      _loadFile();
    }
  }

  Future<void> _loadFile() async {
    final attId = (widget.attachment['id'] ?? widget.attachment['attachment_id'] ?? '').toString();
    final name = (widget.attachment['name'] ?? widget.attachment['file_name'] ?? 'image.png').toString();
    if (attId.isEmpty) {
      if (mounted) setState(() { _isLoading = false; _hasError = true; });
      return;
    }
    setState(() {
      _isLoading = true;
      _hasError = false;
    });
    try {
      final file = await widget.ensureCached(attId, name);
      if (!mounted) return;
      if (file != null && await file.exists()) {
        setState(() {
          _file = file;
          _isLoading = false;
          _hasError = false;
        });
      } else {
        setState(() {
          _isLoading = false;
          _hasError = true;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _hasError = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = (widget.attachment['name'] ?? widget.attachment['file_name'] ?? 'image.png').toString();
    final attId = (widget.attachment['id'] ?? widget.attachment['attachment_id'] ?? '').toString();
    final sizeBytes = (widget.attachment['size'] as num?)?.toInt() ??
        (widget.attachment['file_size'] as num?)?.toInt() ?? 0;
    final sizeStr = sizeBytes > 1024 * 1024
        ? '${(sizeBytes / (1024 * 1024)).toStringAsFixed(1)} МБ'
        : '${(sizeBytes / 1024).toStringAsFixed(1)} КБ';

    if (_file != null) {
      return Container(
        margin: const EdgeInsets.only(top: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: widget.isMe
                ? Colors.white24
                : theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(11),
          child: Stack(
            children: [
              GestureDetector(
                onTap: () => widget.onPreview(attId, name),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxHeight: 280,
                    maxWidth: 320,
                    minWidth: 160,
                  ),
                  child: Image.file(
                    _file!,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => _buildFallback(theme, name, sizeStr, attId),
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [Colors.black87, Colors.transparent],
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        sizeStr,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.white,
                          fontWeight: FontWeight.w500,
                          shadows: [Shadow(color: Colors.black54, blurRadius: 4)],
                        ),
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                            icon: const Icon(Icons.fullscreen_rounded, size: 20, color: Colors.white),
                            tooltip: 'Открыть нативно',
                            onPressed: () => widget.onPreview(attId, name),
                          ),
                          const SizedBox(width: 4),
                          IconButton(
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                            icon: const Icon(Icons.download_rounded, size: 20, color: Colors.white),
                            tooltip: 'Скачать файл',
                            onPressed: () => widget.onSave(attId, name),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (_isLoading) {
      return Container(
        margin: const EdgeInsets.only(top: 6),
        width: 220,
        height: 140,
        decoration: BoxDecoration(
          color: widget.isMe
              ? Colors.white.withValues(alpha: 0.15)
              : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.8),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: widget.isMe
                ? Colors.white24
                : theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 26,
              height: 26,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                color: widget.isMe ? Colors.white : theme.colorScheme.primary,
              ),
            ),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: widget.isMe ? Colors.white : theme.colorScheme.onSurface,
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              sizeStr,
              style: TextStyle(
                fontSize: 11,
                color: widget.isMe ? Colors.white70 : theme.colorScheme.outline,
              ),
            ),
          ],
        ),
      );
    }

    return _buildFallback(theme, name, sizeStr, attId);
  }

  Widget _buildFallback(ThemeData theme, String name, String sizeStr, String attId) {
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: widget.isMe
            ? Colors.white.withValues(alpha: 0.15)
            : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.8),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: widget.isMe
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
              color: widget.isMe
                  ? Colors.white24
                  : theme.colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              Icons.image_outlined,
              size: 20,
              color: widget.isMe ? Colors.white : theme.colorScheme.primary,
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
                    color: widget.isMe ? Colors.white : theme.colorScheme.onSurface,
                  ),
                ),
                Text(
                  _hasError ? 'Ошибка загрузки • Нажмите для повтора' : sizeStr,
                  style: TextStyle(
                    fontSize: 11,
                    color: _hasError
                        ? theme.colorScheme.error
                        : (widget.isMe ? Colors.white70 : theme.colorScheme.outline),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          if (_hasError)
            IconButton(
              icon: Icon(
                Icons.refresh_rounded,
                size: 20,
                color: widget.isMe ? Colors.white : theme.colorScheme.primary,
              ),
              tooltip: 'Повторить загрузку',
              onPressed: _loadFile,
            )
          else ...[
            IconButton(
              icon: Icon(
                Icons.visibility_outlined,
                size: 20,
                color: widget.isMe ? Colors.white : theme.colorScheme.primary,
              ),
              tooltip: 'Просмотр нативно',
              onPressed: () => widget.onPreview(attId, name),
            ),
            IconButton(
              icon: Icon(
                Icons.download_rounded,
                size: 20,
                color: widget.isMe ? Colors.white : theme.colorScheme.primary,
              ),
              tooltip: 'Скачать файл',
              onPressed: () => widget.onSave(attId, name),
            ),
          ],
        ],
      ),
    );
  }
}

class _ChatVideoAttachmentPreview extends StatefulWidget {
  final Map<String, dynamic> attachment;
  final bool isMe;
  final ApiClient? apiClient;
  final Future<File?> Function(String attId, String fileName, {List<int>? initialBytes}) ensureCached;
  final void Function(String attId, String fileName) onPreview;
  final void Function(String attId, String fileName) onSave;

  const _ChatVideoAttachmentPreview({
    required this.attachment,
    required this.isMe,
    required this.apiClient,
    required this.ensureCached,
    required this.onPreview,
    required this.onSave,
  });

  @override
  State<_ChatVideoAttachmentPreview> createState() => _ChatVideoAttachmentPreviewState();
}

class _ChatVideoAttachmentPreviewState extends State<_ChatVideoAttachmentPreview> {
  void _handlePlay() {
    final attId = (widget.attachment['id'] ?? widget.attachment['attachment_id'] ?? '').toString();
    final name = (widget.attachment['name'] ?? widget.attachment['file_name'] ?? 'video.mp4').toString();
    widget.onPreview(attId, name);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = (widget.attachment['name'] ?? widget.attachment['file_name'] ?? 'Видео').toString();
    final attId = (widget.attachment['id'] ?? widget.attachment['attachment_id'] ?? '').toString();
    final sizeBytes = (widget.attachment['size'] as num?)?.toInt() ??
        (widget.attachment['file_size'] as num?)?.toInt() ?? 0;
    final sizeStr = sizeBytes > 1024 * 1024
        ? '${(sizeBytes / (1024 * 1024)).toStringAsFixed(1)} МБ'
        : '${(sizeBytes / 1024).toStringAsFixed(1)} КБ';

    final ext = name.contains('.') ? name.split('.').last.toUpperCase() : 'VIDEO';

    return Container(
      margin: const EdgeInsets.only(top: 6),
      constraints: const BoxConstraints(
        maxWidth: 320,
        minWidth: 220,
        maxHeight: 180,
        minHeight: 130,
      ),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: widget.isMe
              ? [const Color(0xFF1E3A5F), const Color(0xFF122338)]
              : [const Color(0xFF1F2430), const Color(0xFF131720)],
        ),
        border: Border.all(
          color: widget.isMe
              ? Colors.white24
              : theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.25),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(11),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: _handlePlay,
            child: Stack(
              children: [
                const Positioned.fill(
                  child: Opacity(
                    opacity: 0.08,
                    child: Center(
                      child: Icon(
                        Icons.videocam_rounded,
                        size: 110,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: 8,
                  left: 10,
                  right: 10,
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: Colors.white24, width: 0.5),
                        ),
                        child: Text(
                          ext,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            shadows: [Shadow(color: Colors.black87, blurRadius: 4)],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Center(
                  child: Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.black.withValues(alpha: 0.6),
                      border: Border.all(color: Colors.white.withValues(alpha: 0.8), width: 2),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.4),
                          blurRadius: 10,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.play_arrow_rounded,
                      size: 34,
                      color: Colors.white,
                    ),
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: [Colors.black87, Colors.transparent],
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.movie_outlined, size: 14, color: Colors.white70),
                            const SizedBox(width: 4),
                            Text(
                              sizeStr,
                              style: const TextStyle(
                                fontSize: 11,
                                color: Colors.white,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                              icon: const Icon(Icons.fullscreen_rounded, size: 20, color: Colors.white),
                              tooltip: 'Смотреть нативно',
                              onPressed: _handlePlay,
                            ),
                            const SizedBox(width: 4),
                            IconButton(
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                              icon: const Icon(Icons.download_rounded, size: 20, color: Colors.white),
                              tooltip: 'Скачать файл',
                              onPressed: () => widget.onSave(attId, name),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
