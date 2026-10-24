import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../i18n/app_strings.dart';
import '../services/link_host_session.dart';
import 'support_approval_modal.dart';

/// Link uses the actual SOS approval component, not a separate consent form.
class LinkHostOverlay extends StatefulWidget {
  const LinkHostOverlay({required this.state, super.key});
  final LinkHostWorkerState state;
  @override
  State<LinkHostOverlay> createState() => _LinkHostOverlayState();
}

class _LinkHostOverlayState extends State<LinkHostOverlay>
    with WindowListener, TrayListener {
  Size? _currentWindowSize;
  bool _chatOpen = false;
  Future<void> _windowUpdates = Future<void>.value();
  final TextEditingController _chatController = TextEditingController();
  final ScrollController _chatScrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    if (!kIsWeb &&
        (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
      trayManager.addListener(this);
      _initTray();
    }
    widget.state.addListener(_syncWindow);
    unawaited(windowManager.setPreventClose(true));
    _syncWindow();
  }

  Future<void> _initTray() async {
    if (kIsWeb ||
        !(Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
      return;
    }
    try {
      await trayManager.setIcon(
        Platform.isWindows
            ? 'assets/icons/app_icon.ico'
            : 'assets/icons/app_icon.png',
      );
      final menu = Menu(
        items: [
          MenuItem(
            key: 'show',
            label: 'Показать панель сессии',
          ),
          MenuItem.separator(),
          MenuItem(
            key: 'disconnect',
            label: 'Отключить сессию',
          ),
        ],
      );
      await trayManager.setContextMenu(menu);
      await trayManager.setToolTip('Ligament Link: Сеанс удалённого доступа');
    } catch (_) {}
  }

  void _syncWindow() {
    final phase = widget.state.phase;
    if (phase == LinkHostWorkerPhase.starting ||
        phase == LinkHostWorkerPhase.closing ||
        phase == LinkHostWorkerPhase.closed) {
      return;
    }
    final expanded = phase == LinkHostWorkerPhase.awaitingConsent;
    final targetSize = expanded
        ? const Size(560, 760)
        : (_chatOpen ? const Size(560, 480) : const Size(560, 84));
    if (_currentWindowSize == targetSize) return;
    _currentWindowSize = targetSize;
    _windowUpdates = _windowUpdates.then((_) async {
      if (!mounted) return;
      await windowManager.setMinimumSize(const Size(400, 72));
      await windowManager.setSize(targetSize);
      if (expanded) {
        await windowManager.center();
        await windowManager.show();
        await windowManager.focus();
      } else {
        await windowManager.setAlwaysOnTop(true);
        await windowManager.show();
      }
    }).catchError((Object error) {
      debugPrint('link_host: window layout unavailable: ${error.runtimeType}');
    });
  }

  void _toggleChat() {
    setState(() {
      _chatOpen = !_chatOpen;
      if (_chatOpen) {
        widget.state.clearUnreadChat();
      }
    });
    _syncWindow();
  }

  void _submitChatMessage() {
    final text = _chatController.text.trim();
    if (text.isEmpty) return;
    widget.state.sendChatMessage(text);
    _chatController.clear();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_chatScrollController.hasClients) {
        _chatScrollController.animateTo(
          _chatScrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  void dispose() {
    _chatController.dispose();
    _chatScrollController.dispose();
    if (!kIsWeb &&
        (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
      try {
        trayManager.removeListener(this);
        trayManager.destroy();
      } catch (_) {}
    }
    widget.state.removeListener(_syncWindow);
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowClose() => widget.state.requestDisconnect();

  @override
  void onWindowMinimize() => _minimizeToTray();

  @override
  void onTrayIconMouseDown() {
    _restoreOverlay();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    if (menuItem.key == 'show') {
      _restoreOverlay();
    } else if (menuItem.key == 'disconnect') {
      widget.state.requestDisconnect();
    }
  }

  void _restoreOverlay() {
    _windowUpdates = _windowUpdates.then((_) async {
      if (!mounted) return;
      if (await windowManager.isMinimized()) {
        await windowManager.restore();
      }
      await windowManager.show();
      await windowManager.focus();
      await windowManager.setAlwaysOnTop(true);
    }).catchError((Object error) {
      debugPrint('link_host: restore overlay failed: $error');
    });
  }

  void _minimizeToTray() {
    _windowUpdates = _windowUpdates.then((_) async {
      if (!mounted) return;
      await windowManager.hide();
    }).catchError((Object error) {
      debugPrint('link_host: minimize to tray failed: $error');
    });
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          backgroundColor: const Color(0xFF10251D),
          body: SafeArea(
              child: AnimatedBuilder(
            animation: widget.state,
            builder: (context, _) {
              final state = widget.state;
              if (state.phase == LinkHostWorkerPhase.awaitingConsent) {
                return Center(
                    child: SingleChildScrollView(
                        child: SupportApprovalModal(
                  key: ValueKey(state.sessionId),
                  stringsOverride: AppStrings('ru'),
                  prompt: <String, dynamic>{
                    'session_id': state.sessionId,
                    'admin_name': state.operatorName,
                    'access_mode': state.accessMode == 'control'
                        ? 'full_control'
                        : 'view_only',
                    'problem_summary': state.recordingEnabled
                        ? 'Ligament Link · Ведётся запись сессии'
                        : 'Ligament Link',
                    'category': 'it',
                  },
                  // Only length reaches the host; the server verifies the digits.
                  numberMatchLength: state.confirmationDigits,
                  onApprove: (code) async => state.approveConsent(code),
                  onDeny: () async => state.denyConsent(),
                )));
              }
              final closing = state.phase == LinkHostWorkerPhase.closing ||
                  state.phase == LinkHostWorkerPhase.closed;
              final isUnattended = state.accessType == 'unattended';
              final status = switch (state.phase) {
                LinkHostWorkerPhase.starting => 'Подготовка защищённого канала',
                LinkHostWorkerPhase.awaitingConsent => 'Ожидание подтверждения',
                LinkHostWorkerPhase.connecting =>
                  isUnattended ? 'Подключение администратора…' : 'Удалённое подключение устанавливается',
                LinkHostWorkerPhase.active =>
                  isUnattended ? 'Сеанс удалённого доступа' : 'Удалённая сессия активна',
                LinkHostWorkerPhase.closing => 'Отключение…',
                LinkHostWorkerPhase.closed => 'Сессия завершена',
              };
              return Column(
                children: [
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    child: Row(children: [
                      const Icon(Icons.screen_share, color: Color(0xFF4ADE80)),
                      const SizedBox(width: 12),
                      Expanded(
                          child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(status,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w700)),
                          const SizedBox(height: 4),
                          Text(
                              '${state.operatorName.isNotEmpty ? state.operatorName : "Оператор"} · ${state.accessMode == 'control' ? 'Управление' : 'Просмотр'}${isUnattended ? " (без кода)" : ""}${state.recordingEnabled ? " · ⏺ Запись сессии" : ""}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  color: Color(0xFFB7C8BE), fontSize: 12)),
                        ],
                      )),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        onPressed: closing ? null : _toggleChat,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: _chatOpen
                              ? const Color(0xFF4ADE80)
                              : const Color(0xFFB7C8BE),
                          side: BorderSide(
                            color: _chatOpen
                                ? const Color(0xFF4ADE80)
                                : const Color(0xFF2D5A46),
                          ),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 8),
                          visualDensity: VisualDensity.compact,
                        ),
                        icon: Badge(
                          isLabelVisible: state.unreadChatCount > 0 && !_chatOpen,
                          label: Text('${state.unreadChatCount}'),
                          child: Icon(
                            _chatOpen
                                ? Icons.chat
                                : Icons.chat_bubble_outline,
                            size: 16,
                          ),
                        ),
                        label: Text(_chatOpen ? 'Закрыть чат' : 'Чат',
                            style: const TextStyle(fontSize: 12)),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        onPressed: closing ? null : _minimizeToTray,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFFB7C8BE),
                          side: const BorderSide(color: Color(0xFF2D5A46)),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 8),
                          visualDensity: VisualDensity.compact,
                        ),
                        icon: const Icon(Icons.vertical_align_bottom, size: 16),
                        label: const Text('Свернуть в трей',
                            style: TextStyle(fontSize: 12)),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                          onPressed: closing ? null : state.requestDisconnect,
                          style: FilledButton.styleFrom(
                              backgroundColor: const Color(0xFFB42318),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 14, vertical: 8),
                              visualDensity: VisualDensity.compact),
                          child: const Text('Отключить')),
                    ]),
                  ),
                  if (_chatOpen) ...[
                    const Divider(height: 1, color: Color(0xFF2D5A46)),
                    Expanded(
                      child: Container(
                        color: const Color(0xFF0F1E17),
                        child: Column(
                          children: [
                            Expanded(
                              child: state.chatMessages.isEmpty
                                  ? const Center(
                                      child: Text(
                                        'Нет сообщений. Напишите оператору.',
                                        style: TextStyle(
                                            color: Color(0xFF718096),
                                            fontSize: 13),
                                      ),
                                    )
                                  : ListView.builder(
                                      controller: _chatScrollController,
                                      padding: const EdgeInsets.all(12),
                                      itemCount: state.chatMessages.length,
                                      itemBuilder: (context, idx) {
                                        final msg = state.chatMessages[idx];
                                        final isMe = msg.sender == 'user';
                                        return Align(
                                          alignment: isMe
                                              ? Alignment.centerRight
                                              : Alignment.centerLeft,
                                          child: Container(
                                            margin: const EdgeInsets.symmetric(
                                                vertical: 4),
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 12, vertical: 8),
                                            constraints: BoxConstraints(
                                              maxWidth: MediaQuery.of(context)
                                                      .size
                                                      .width *
                                                  0.75,
                                            ),
                                            decoration: BoxDecoration(
                                              color: isMe
                                                  ? const Color(0xFF065F46)
                                                  : const Color(0xFF1E293B),
                                              borderRadius:
                                                  BorderRadius.circular(10),
                                              border: Border.all(
                                                color: isMe
                                                    ? const Color(0xFF059669)
                                                    : const Color(0xFF334155),
                                              ),
                                            ),
                                            child: Column(
                                              crossAxisAlignment: isMe
                                                  ? CrossAxisAlignment.end
                                                  : CrossAxisAlignment.start,
                                              children: [
                                                if (!isMe &&
                                                    msg.senderName.isNotEmpty)
                                                  Padding(
                                                    padding: const EdgeInsets.only(
                                                        bottom: 4),
                                                    child: Text(
                                                      msg.senderName,
                                                      style: const TextStyle(
                                                        color: Color(0xFF38BDF8),
                                                        fontSize: 11,
                                                        fontWeight:
                                                            FontWeight.w600,
                                                      ),
                                                    ),
                                                  ),
                                                Text(
                                                  msg.text,
                                                  style: const TextStyle(
                                                    color: Colors.white,
                                                    fontSize: 13,
                                                  ),
                                                ),
                                                const SizedBox(height: 2),
                                                Text(
                                                  '${msg.timestamp.hour.toString().padLeft(2, '0')}:${msg.timestamp.minute.toString().padLeft(2, '0')}',
                                                  style: const TextStyle(
                                                    color: Color(0xFF94A3B8),
                                                    fontSize: 10,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        );
                                      },
                                    ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 8),
                              decoration: const BoxDecoration(
                                color: Color(0xFF10251D),
                                border: Border(
                                  top: BorderSide(color: Color(0xFF2D5A46)),
                                ),
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: TextField(
                                      controller: _chatController,
                                      style: const TextStyle(
                                          color: Colors.white, fontSize: 13),
                                      decoration: InputDecoration(
                                        hintText: 'Введите сообщение…',
                                        hintStyle: const TextStyle(
                                            color: Color(0xFF718096),
                                            fontSize: 13),
                                        filled: true,
                                        fillColor: const Color(0xFF1E293B),
                                        contentPadding:
                                            const EdgeInsets.symmetric(
                                                horizontal: 12, vertical: 8),
                                        border: OutlineInputBorder(
                                          borderRadius:
                                              BorderRadius.circular(8),
                                          borderSide: BorderSide.none,
                                        ),
                                      ),
                                      onSubmitted: (_) => _submitChatMessage(),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  IconButton(
                                    onPressed: _submitChatMessage,
                                    icon: const Icon(Icons.send,
                                        color: Color(0xFF4ADE80), size: 20),
                                    tooltip: 'Отправить',
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ],
              );
            },
          )),
        ),
      );
}
