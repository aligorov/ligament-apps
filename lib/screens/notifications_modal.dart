import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../services/auth_state.dart';
import '../i18n/app_strings.dart';

/// Модальное окно / панель «Центр уведомлений» (Notification Inbox)
class NotificationsModal extends StatefulWidget {
  const NotificationsModal({super.key});

  /// Показывает адаптивный центр уведомлений
  static Future<void> show(BuildContext context) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const NotificationsModal(),
    );
  }

  @override
  State<NotificationsModal> createState() => _NotificationsModalState();
}

class _NotificationsModalState extends State<NotificationsModal> {
  String _filter = 'all';

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthState>();
    final s = context.strings;
    final isRu = auth.isRu;
    final notifications = auth.notifications;
    final unreadCount = auth.unreadNotificationsCount;

    String getTopic(Map<String, dynamic> item) {
      final t = (item['topic']?.toString() ?? item['source']?.toString() ?? 'system').trim();
      return t.isEmpty ? 'system' : t;
    }

    String topicLabel(String key) {
      final lower = key.toLowerCase();
      if (lower == 'security') return isRu ? 'Безопасность' : 'Security';
      if (lower == 'radius') return 'RADIUS';
      if (lower == 'tg' || lower == 'telegram') return 'Telegram';
      if (lower == 'ha' || lower == 'homeassistant') return 'Home Assistant';
      if (lower == 'mikrotik') return 'MikroTik';
      if (lower == 'frigate') return 'Frigate';
      if (lower == 'system') return isRu ? 'Системные' : 'System';
      return key.toUpperCase();
    }

    final Map<String, int> topicCounts = {};
    final Map<String, String> topicLabels = {};
    for (final item in notifications) {
      final key = getTopic(item);
      final lower = key.toLowerCase();
      topicCounts[lower] = (topicCounts[lower] ?? 0) + 1;
      topicLabels.putIfAbsent(lower, () => topicLabel(key));
    }

    final filtered = notifications.where((item) {
      if (_filter == 'all') return true;
      return getTopic(item).toLowerCase() == _filter.toLowerCase();
    }).toList();

    final screenHeight = MediaQuery.of(context).size.height;
    final screenWidth = MediaQuery.of(context).size.width;
    final maxModalWidth = screenWidth > 640 ? 600.0 : screenWidth;

    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: maxModalWidth,
          maxHeight: screenHeight * 0.85,
        ),
        child: Container(
          decoration: const BoxDecoration(
            color: Color(0xFF0F172A),
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
            boxShadow: [
              BoxShadow(
                color: Colors.black54,
                blurRadius: 24,
                spreadRadius: 4,
              ),
            ],
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Индикатор drag handle для мобильных экранов
                Container(
                  margin: const EdgeInsets.only(top: 10, bottom: 6),
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: const Color(0xFF475569),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),

                // Заголовок панели
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: const Color(0xFF0284C7).withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: const Color(0xFF0284C7).withValues(alpha: 0.4)),
                        ),
                        child: const Icon(
                          Icons.notifications_active_rounded,
                          color: Color(0xFF38BDF8),
                          size: 20,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: Text(
                                s.notificationsTitle,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (unreadCount > 0) ...[
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF0284C7),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Text(
                                  '$unreadCount',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      if (unreadCount > 0)
                        IconButton(
                          icon: const Icon(Icons.done_all, size: 20, color: Color(0xFF38BDF8)),
                          tooltip: s.markAllRead,
                          onPressed: () async {
                            try {
                              await auth.markAllNotificationsRead();
                            } catch (_) {
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(s.networkError),
                                    backgroundColor: const Color(0xFFEF4444),
                                  ),
                                );
                              }
                            }
                          },
                        ),
                      IconButton(
                        icon: const Icon(Icons.refresh, size: 20, color: Color(0xFF94A3B8)),
                        tooltip: s.refresh,
                        onPressed: () => auth.loadNotifications(),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, size: 20, color: Color(0xFF94A3B8)),
                        tooltip: s.close,
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ],
                  ),
                ),
                const Divider(color: Color(0xFF1E293B), height: 1),

                // Динамическая строка чипсов по темам сообщений
                if (notifications.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    color: const Color(0xFF1E293B).withValues(alpha: 0.4),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          _filterChip('all', isRu ? 'Все' : 'All', notifications.length),
                          ...topicCounts.keys.map((k) {
                            return Padding(
                              padding: const EdgeInsets.only(left: 8),
                              child: _filterChip(
                                k,
                                topicLabels[k] ?? k.toUpperCase(),
                                topicCounts[k] ?? 0,
                              ),
                            );
                          }),
                        ],
                      ),
                    ),
                  ),

                // Содержимое
                Expanded(
                  child: filtered.isEmpty
                      ? _buildEmptyState(context, s)
                      : RefreshIndicator(
                          onRefresh: () => auth.loadNotifications(),
                          color: const Color(0xFF38BDF8),
                          child: ListView.separated(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                            itemCount: filtered.length,
                            separatorBuilder: (_, __) => const SizedBox(height: 10),
                            itemBuilder: (ctx, index) {
                              final item = filtered[index];
                              return _buildNotificationCard(ctx, auth, item, isRu);
                            },
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

  Widget _filterChip(String filterKey, String label, int count) {
    final isSelected = _filter == filterKey;
    return InkWell(
      onTap: () => setState(() => _filter = filterKey),
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF0284C7) : const Color(0xFF0F172A),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isSelected ? const Color(0xFF38BDF8) : const Color(0xFF334155),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                color: isSelected ? Colors.white : const Color(0xFF94A3B8),
                fontSize: 11,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
              ),
            ),
            if (count > 0) ...[
              const SizedBox(width: 5),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: isSelected ? Colors.white.withValues(alpha: 0.25) : const Color(0xFF1E293B),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  '$count',
                  style: TextStyle(
                    color: isSelected ? Colors.white : const Color(0xFF64748B),
                    fontSize: 9,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context, AppStrings s) {
    return Center(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFF1E293B),
                  border: Border.all(color: const Color(0xFF334155)),
                ),
                child: const Icon(
                  Icons.notifications_none_rounded,
                  size: 36,
                  color: Color(0xFF64748B),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                s.noNotifications,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                s.noNotificationsDesc,
                style: const TextStyle(
                  color: Color(0xFF94A3B8),
                  fontSize: 13,
                  height: 1.4,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNotificationCard(
    BuildContext context,
    AuthState auth,
    Map<String, dynamic> item,
    bool isRu,
  ) {
    final id = item['id']?.toString() ?? '';
    final isRead = item['is_read'] == true || item['read_at'] != null;
    final subject = item['subject']?.toString() ?? (isRu ? 'Уведомление' : 'Notification');
    final body = item['body']?.toString() ?? '';
    final topic = (item['topic']?.toString() ?? item['source']?.toString() ?? 'system').trim();
    final imageUrl = (item['image_url']?.toString() ?? item['image']?.toString() ?? '').trim();
    final status = item['status']?.toString() ?? '';

    DateTime? createdAt;
    final rawCreated = item['created_at']?.toString();
    if (rawCreated != null) {
      createdAt = DateTime.tryParse(rawCreated)?.toLocal();
    }
    final timeStr = createdAt != null
        ? DateFormat('dd.MM.yyyy HH:mm').format(createdAt)
        : '';

    IconData iconData = Icons.notifications_rounded;
    Color iconColor = const Color(0xFF38BDF8);
    Color iconBg = const Color(0xFF0284C7).withValues(alpha: 0.15);

    final normTopic = topic.toLowerCase();
    if (normTopic.contains('radius')) {
      iconData = Icons.router_outlined;
      iconColor = const Color(0xFFF59E0B);
      iconBg = const Color(0xFFF59E0B).withValues(alpha: 0.15);
    } else if (normTopic.contains('tg') || normTopic.contains('telegram')) {
      iconData = Icons.send_rounded;
      iconColor = const Color(0xFF38BDF8);
      iconBg = const Color(0xFF0284C7).withValues(alpha: 0.15);
    } else if (normTopic.contains('ha') || normTopic.contains('homeassistant')) {
      iconData = Icons.home_rounded;
      iconColor = const Color(0xFF06B6D4);
      iconBg = const Color(0xFF06B6D4).withValues(alpha: 0.15);
    } else if (normTopic.contains('mikrotik')) {
      iconData = Icons.dns_rounded;
      iconColor = const Color(0xFF3B82F6);
      iconBg = const Color(0xFF3B82F6).withValues(alpha: 0.15);
    } else if (normTopic.contains('frigate') || normTopic.contains('cam')) {
      iconData = Icons.videocam_rounded;
      iconColor = const Color(0xFFF97316);
      iconBg = const Color(0xFFF97316).withValues(alpha: 0.15);
    } else if (normTopic.contains('email') || normTopic.contains('mail')) {
      iconData = Icons.mail_outline_rounded;
      iconColor = const Color(0xFFA78BFA);
      iconBg = const Color(0xFF8B5CF6).withValues(alpha: 0.15);
    } else if (normTopic.contains('app') || normTopic.contains('push')) {
      iconData = Icons.smartphone_rounded;
      iconColor = const Color(0xFF10B981);
      iconBg = const Color(0xFF10B981).withValues(alpha: 0.15);
    } else if (normTopic.contains('security') || normTopic.contains('alert')) {
      iconData = Icons.security_rounded;
      iconColor = const Color(0xFFEF4444);
      iconBg = const Color(0xFFEF4444).withValues(alpha: 0.15);
    } else if (normTopic != 'system') {
      iconData = Icons.label_important_outline_rounded;
      iconColor = const Color(0xFFA855F7);
      iconBg = const Color(0xFFA855F7).withValues(alpha: 0.15);
    }

    return InkWell(
      onTap: () {
        if (!isRead && id.isNotEmpty) {
          auth.markNotificationRead(id);
        }
      },
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isRead ? const Color(0xFF1E293B).withValues(alpha: 0.5) : const Color(0xFF1E293B),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isRead
                ? const Color(0xFF334155).withValues(alpha: 0.6)
                : const Color(0xFF0284C7).withValues(alpha: 0.8),
            width: isRead ? 1 : 1.5,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Иконка типа/источника сообщения
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: iconBg,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(iconData, color: iconColor, size: 20),
            ),
            const SizedBox(width: 12),

            // Текст и метаданные сообщения
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          subject,
                          style: TextStyle(
                            color: isRead ? const Color(0xFFCBD5E1) : Colors.white,
                            fontSize: 14,
                            fontWeight: isRead ? FontWeight.w500 : FontWeight.bold,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (!isRead) ...[
                        const SizedBox(width: 6),
                        Container(
                          width: 8,
                          height: 8,
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: Color(0xFF38BDF8),
                          ),
                        ),
                      ],
                    ],
                  ),
                  if (body.isNotEmpty) ...[
                    const SizedBox(height: 5),
                    Text(
                      body,
                      style: TextStyle(
                        color: isRead ? const Color(0xFF94A3B8) : const Color(0xFFE2E8F0),
                        fontSize: 13,
                        height: 1.35,
                      ),
                    ),
                  ],
                  if (imageUrl.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 180),
                        child: Image.network(
                          imageUrl,
                          width: double.infinity,
                          fit: BoxFit.cover,
                          errorBuilder: (ctx, err, stack) => const SizedBox.shrink(),
                          loadingBuilder: (ctx, child, progress) {
                            if (progress == null) return child;
                            return Container(
                              height: 100,
                              color: const Color(0xFF0F172A),
                              child: const Center(
                                child: SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF38BDF8)),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      // Бейдж темы/источника
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: const Color(0xFF0F172A),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: const Color(0xFF334155)),
                        ),
                        child: Text(
                          topic.toUpperCase(),
                          style: TextStyle(
                            color: iconColor,
                            fontSize: 9,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                      if (status.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        Text(
                          status,
                          style: const TextStyle(
                            color: Color(0xFF64748B),
                            fontSize: 10,
                          ),
                        ),
                      ],
                      const Spacer(),
                      if (timeStr.isNotEmpty) ...[
                        Text(
                          timeStr,
                          style: const TextStyle(
                            color: Color(0xFF64748B),
                            fontSize: 11,
                          ),
                        ),
                      ],
                      if (isRead) ...[
                        const SizedBox(width: 6),
                        const Icon(
                          Icons.done_all,
                          size: 14,
                          color: Color(0xFF10B981),
                        ),
                      ],
                    ],
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
