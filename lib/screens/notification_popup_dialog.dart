import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../services/auth_state.dart';
import 'notifications_modal.dart';

/// Всплывающее диалоговое окно для входящих текстовых push-уведомлений
class NotificationPopupDialog extends StatelessWidget {
  final Map<String, dynamic> notification;

  const NotificationPopupDialog({
    super.key,
    required this.notification,
  });

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthState>();
    final isRu = auth.isRu;

    final id = notification['id']?.toString() ?? '';
    final title = notification['title']?.toString() ??
        notification['subject']?.toString() ??
        (isRu ? 'Новое уведомление' : 'New Notification');
    final body = notification['body']?.toString() ?? '';
    final source = (notification['source']?.toString() ?? 'system').toLowerCase();

    DateTime? createdAt;
    final rawCreated = notification['created_at']?.toString() ?? notification['timestamp']?.toString();
    if (rawCreated != null) {
      createdAt = DateTime.tryParse(rawCreated)?.toLocal();
    }
    createdAt ??= DateTime.now();
    final timeStr = DateFormat('HH:mm:ss, dd MMM').format(createdAt);

    IconData iconData = Icons.notifications_active_rounded;
    Color iconColor = const Color(0xFF38BDF8);
    Color iconBg = const Color(0xFF0284C7).withValues(alpha: 0.2);

    if (source.contains('radius')) {
      iconData = Icons.router_outlined;
      iconColor = const Color(0xFFF59E0B);
      iconBg = const Color(0xFFF59E0B).withValues(alpha: 0.2);
    } else if (source.contains('tg') || source.contains('telegram')) {
      iconData = Icons.send_rounded;
      iconColor = const Color(0xFF38BDF8);
      iconBg = const Color(0xFF0284C7).withValues(alpha: 0.2);
    } else if (source.contains('email') || source.contains('mail')) {
      iconData = Icons.mail_outline_rounded;
      iconColor = const Color(0xFFA78BFA);
      iconBg = const Color(0xFF8B5CF6).withValues(alpha: 0.2);
    } else if (source.contains('app') || source.contains('push')) {
      iconData = Icons.smartphone_rounded;
      iconColor = const Color(0xFF10B981);
      iconBg = const Color(0xFF10B981).withValues(alpha: 0.2);
    } else if (source.contains('security') || source.contains('alert')) {
      iconData = Icons.security_rounded;
      iconColor = const Color(0xFFEF4444);
      iconBg = const Color(0xFFEF4444).withValues(alpha: 0.2);
    }

    return AlertDialog(
      backgroundColor: const Color(0xFF1E293B),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: iconColor.withValues(alpha: 0.4), width: 1.5),
      ),
      titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
      contentPadding: const EdgeInsets.symmetric(horizontal: 20),
      actionsPadding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
      title: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: iconBg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: iconColor.withValues(alpha: 0.3)),
            ),
            child: Icon(iconData, color: iconColor, size: 24),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
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
                        source.toUpperCase(),
                        style: TextStyle(
                          color: iconColor,
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      timeStr,
                      style: const TextStyle(
                        color: Color(0xFF94A3B8),
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 20, color: Color(0xFF94A3B8)),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
      content: SingleChildScrollView(
        child: Container(
          width: double.maxFinite,
          constraints: const BoxConstraints(maxWidth: 480),
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Divider(color: Color(0xFF334155), height: 16),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFF0F172A),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFF334155)),
                ),
                child: SelectableText(
                  body.isNotEmpty ? body : (isRu ? 'Текст уведомления отсутствует' : 'No message body'),
                  style: const TextStyle(
                    color: Color(0xFFF1F5F9),
                    fontSize: 14,
                    height: 1.45,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        Row(
          children: [
            TextButton.icon(
              onPressed: () {
                Navigator.of(context).pop();
                NotificationsModal.show(context);
              },
              icon: const Icon(Icons.all_inbox_rounded, size: 16, color: Color(0xFF94A3B8)),
              label: Text(
                isRu ? 'Все' : 'All',
                style: const TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
              ),
            ),
            const Spacer(),
            ElevatedButton.icon(
              onPressed: () {
                if (id.isNotEmpty) {
                  auth.markNotificationRead(id);
                }
                Navigator.of(context).pop();
              },
              icon: const Icon(Icons.check, size: 18),
              label: Text(
                isRu ? 'Понятно' : 'Got it',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF0284C7),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
