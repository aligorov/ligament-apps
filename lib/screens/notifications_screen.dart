import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../services/auth_state.dart';
import '../i18n/app_strings.dart';
import '../widgets/app_update_banner.dart';
import 'notification_popup_dialog.dart';

/// Полноэкранный раздел «Сообщения и уведомления» (Inbox)
class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  String _filter = 'all'; // all, security, radius, telegram, system
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthState>();
    final s = context.strings;
    final isRu = auth.isRu;
    final allNotifications = auth.notifications;
    final unreadCount = auth.unreadNotificationsCount;

    // Динамический сбор уникальных тем и подсчет сообщений
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
    for (final item in allNotifications) {
      final key = getTopic(item);
      final lower = key.toLowerCase();
      topicCounts[lower] = (topicCounts[lower] ?? 0) + 1;
      topicLabels.putIfAbsent(lower, () => topicLabel(key));
    }

    // Фильтрация
    final filtered = allNotifications.where((item) {
      final itemTopic = getTopic(item).toLowerCase();
      if (_filter != 'all' && itemTopic != _filter.toLowerCase()) {
        return false;
      }

      if (_searchQuery.isNotEmpty) {
        final q = _searchQuery.toLowerCase();
        final subject = (item['subject']?.toString() ?? '').toLowerCase();
        final body = (item['body']?.toString() ?? '').toLowerCase();
        if (!subject.contains(q) && !body.contains(q)) {
          return false;
        }
      }

      return true;
    }).toList();

    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E293B),
        title: Row(
          children: [
            const Icon(Icons.mark_email_unread_outlined, color: Color(0xFF38BDF8), size: 22),
            const SizedBox(width: 10),
            Text(
              isRu ? 'Сообщения' : 'Inbox',
              style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
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
        actions: [
          if (unreadCount > 0)
            TextButton.icon(
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
              icon: const Icon(Icons.done_all, size: 16, color: Color(0xFF38BDF8)),
              label: Text(
                s.markAllRead,
                style: const TextStyle(fontSize: 12, color: Color(0xFF38BDF8)),
              ),
            ),
          IconButton(
            icon: const Icon(Icons.refresh, color: Color(0xFF94A3B8)),
            tooltip: s.refresh,
            onPressed: () => auth.loadNotifications(),
          ),
        ],
        bottom: AppUpdateBanner.maybeFromAuth(auth),
      ),
      body: RefreshIndicator(
        onRefresh: () => auth.loadNotifications(),
        color: const Color(0xFF38BDF8),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: TextField(
                controller: _searchController,
                onChanged: (val) => setState(() => _searchQuery = val.trim()),
                style: const TextStyle(color: Colors.white, fontSize: 13),
                decoration: InputDecoration(
                  hintText: isRu ? 'Поиск по сообщениям...' : 'Search messages...',
                  hintStyle: const TextStyle(color: Color(0xFF64748B), fontSize: 13),
                  prefixIcon: const Icon(Icons.search, color: Color(0xFF64748B), size: 18),
                  suffixIcon: _searchQuery.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear, color: Color(0xFF64748B), size: 16),
                          onPressed: () {
                            _searchController.clear();
                            setState(() => _searchQuery = '');
                          },
                        )
                      : null,
                  filled: true,
                  fillColor: const Color(0xFF1E293B),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: Color(0xFF334155)),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: Color(0xFF334155)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: Color(0xFF38BDF8)),
                  ),
                ),
              ),
            ),
            // Динамические фильтры по темам сообщений
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              color: const Color(0xFF1E293B).withValues(alpha: 0.6),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _filterChip('all', isRu ? 'Все' : 'All', allNotifications.length),
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

            // Список уведомлений
            Expanded(
              child: filtered.isEmpty
                  ? _buildEmptyState(s, isRu)
                  : ListView.separated(
                      padding: const EdgeInsets.all(16),
                      itemCount: filtered.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 10),
                      itemBuilder: (ctx, index) {
                        final item = filtered[index];
                        return _buildCard(ctx, auth, item, isRu);
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _filterChip(String filterKey, String label, int count) {
    final isSelected = _filter == filterKey;
    return InkWell(
      onTap: () => setState(() => _filter = filterKey),
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF0284C7) : const Color(0xFF0F172A),
          borderRadius: BorderRadius.circular(16),
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
                fontSize: 12,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
              ),
            ),
            if (count > 0) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: isSelected ? Colors.white.withValues(alpha: 0.25) : const Color(0xFF1E293B),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '$count',
                  style: TextStyle(
                    color: isSelected ? Colors.white : const Color(0xFF64748B),
                    fontSize: 10,
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

  Widget _buildEmptyState(AppStrings s, bool isRu) {
    return Center(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(32),
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
                  Icons.mark_email_read_outlined,
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

  Widget _buildCard(BuildContext context, AuthState auth, Map<String, dynamic> item, bool isRu) {
    final id = item['id']?.toString() ?? '';
    final isRead = item['is_read'] == true || item['read_at'] != null;
    final subject = item['subject']?.toString() ?? (isRu ? 'Уведомление' : 'Notification');
    final body = item['body']?.toString() ?? '';
    final topic = (item['topic']?.toString() ?? item['source']?.toString() ?? 'system').trim();
    final source = (item['source']?.toString() ?? topic).toLowerCase();
    final imageUrl = (item['image_url']?.toString() ?? item['image']?.toString() ?? '').trim();

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
        // Открываем модальный просмотр с полным текстом
        showDialog(
          context: context,
          builder: (_) => NotificationPopupDialog(
            notification: {
              'id': id,
              'title': subject,
              'body': body,
              'source': source,
              'topic': topic,
              'image_url': imageUrl,
              'created_at': rawCreated,
            },
          ),
        );
        if (!isRead && id.isNotEmpty) {
          auth.markNotificationRead(id);
        }
      },
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: isRead ? const Color(0xFF1E293B).withValues(alpha: 0.45) : const Color(0xFF1E293B),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isRead
                ? const Color(0xFF334155).withValues(alpha: 0.5)
                : const Color(0xFF0284C7).withValues(alpha: 0.7),
            width: isRead ? 1 : 1.5,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(9),
              decoration: BoxDecoration(
                color: iconBg,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(iconData, color: iconColor, size: 20),
            ),
            const SizedBox(width: 12),
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
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
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
                        constraints: const BoxConstraints(maxHeight: 200),
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
                      const Spacer(),
                      if (timeStr.isNotEmpty)
                        Text(
                          timeStr,
                          style: const TextStyle(
                            color: Color(0xFF64748B),
                            fontSize: 11,
                          ),
                        ),
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
