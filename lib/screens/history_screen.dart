import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../services/auth_state.dart';
import '../i18n/app_strings.dart';

class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key});

  void _handleEmergencyRevoke(BuildContext context) {
    final s = context.stringsRead;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        title: Row(
          children: [
            const Icon(Icons.warning_amber_rounded, color: Colors.redAccent),
            const SizedBox(width: 8),
            Text(s.notYouTitle, style: const TextStyle(color: Colors.white, fontSize: 18)),
          ],
        ),
        content: Text(
          s.notYouSub,
          style: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(s.cancel, style: const TextStyle(color: Color(0xFF94A3B8))),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.of(ctx).pop();
              final auth = context.read<AuthState>();
              await auth.logout();
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            child: Text(s.emergencyExit, style: const TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  void _showDetailsDialog(BuildContext context, Map<String, dynamic> item) {
    final s = context.stringsRead;
    final isRu = s.isRu;
    final eventTitle = item['event_title']?.toString() ?? _formatEventName(item['event']?.toString() ?? '', isRu);
    final isSuccess = item['result'] == 'ok';
    final resultTitle = item['result_title']?.toString() ?? (isSuccess ? s.statusSuccess : s.statusFailed);
    final service = item['service']?.toString() ?? (isRu ? 'Корпоративный доступ' : 'Corporate Access');
    final clientIp = item['client_ip']?.toString() ?? item['ip']?.toString() ?? '—';
    final hostIp = item['host_ip']?.toString() ?? '';
    final location = item['location']?.toString() ?? clientIp;
    final device = item['device']?.toString() ?? (isRu ? 'Устройство пользователя' : 'User Device');
    final browser = item['browser']?.toString() ?? '';
    final method = item['method']?.toString() ?? (isRu ? 'Пароль / 2FA' : 'Password / 2FA');
    final tsStr = item['timestamp']?.toString();
    DateTime? ts;
    if (tsStr != null) {
      ts = DateTime.tryParse(tsStr)?.toLocal();
    }
    final df = DateFormat('dd.MM.yyyy HH:mm:ss');

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: const Color(0xFF38BDF8).withValues(alpha: 0.3)),
        ),
        title: Row(
          children: [
            Icon(
              isSuccess ? Icons.check_circle_outline : Icons.error_outline,
              color: isSuccess ? const Color(0xFF10B981) : Colors.redAccent,
              size: 24,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                eventTitle,
                style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _detailRow(Icons.check, isRu ? 'Статус:' : 'Status:', resultTitle, isSuccess ? const Color(0xFF10B981) : Colors.redAccent),
              const Divider(color: Color(0xFF334155), height: 16),
              _detailRow(Icons.apps, isRu ? 'Куда (сервис):' : 'Service:', service, const Color(0xFF38BDF8)),
              const Divider(color: Color(0xFF334155), height: 16),
              _detailRow(Icons.wifi, isRu ? 'IP клиента:' : 'Client IP:', _formatIPWithPrivate(clientIp, isRu), Colors.white),
              if (hostIp.isNotEmpty && hostIp != clientIp) ...[
                const Divider(color: Color(0xFF334155), height: 16),
                _detailRow(Icons.dns, isRu ? 'IP сервера:' : 'Server IP:', _formatIPWithPrivate(hostIp, isRu), Colors.white),
              ],
              if (location.isNotEmpty && location != clientIp) ...[
                const Divider(color: Color(0xFF334155), height: 16),
                _detailRow(Icons.map, isRu ? 'Сеть / Маршрут:' : 'Location / Route:', location, const Color(0xFF94A3B8)),
              ],
              const Divider(color: Color(0xFF334155), height: 16),
              _detailRow(Icons.devices, isRu ? 'Устройство:' : 'Device:', device, Colors.white),
              if (browser.isNotEmpty) ...[
                const Divider(color: Color(0xFF334155), height: 16),
                _detailRow(Icons.language, isRu ? 'Клиент / Браузер:' : 'Client / Browser:', browser, Colors.white),
              ],
              const Divider(color: Color(0xFF334155), height: 16),
              _detailRow(Icons.security, isRu ? 'Способ 2FA:' : '2FA Method:', method, const Color(0xFFF59E0B)),
              if (ts != null) ...[
                const Divider(color: Color(0xFF334155), height: 16),
                _detailRow(Icons.access_time, isRu ? 'Время входа:' : 'Login Time:', df.format(ts), const Color(0xFF94A3B8)),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              _handleEmergencyRevoke(context);
            },
            child: Text(isRu ? 'Это не я!' : 'Not me!', style: const TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(),
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF0284C7)),
            child: Text(s.close, style: const TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Widget _detailRow(IconData icon, String label, String value, Color valColor) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: const Color(0xFF94A3B8)),
        const SizedBox(width: 8),
        Text(label, style: const TextStyle(fontSize: 12, color: Color(0xFF94A3B8))),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.end,
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: valColor),
          ),
        ),
      ],
    );
  }

  static bool _isPrivateIP(String ip) {
    if (ip.startsWith('10.') || ip.startsWith('192.168.') || ip == '127.0.0.1' || ip == '::1') {
      return true;
    }
    if (ip.startsWith('172.')) {
      final parts = ip.split('.');
      if (parts.length >= 2) {
        final second = int.tryParse(parts[1]) ?? 0;
        if (second >= 16 && second <= 31) return true;
      }
    }
    return false;
  }

  static String _formatIPWithPrivate(String ip, bool isRu) {
    if (ip.isEmpty || ip == '—') return '—';
    if (_isPrivateIP(ip)) {
      return isRu ? '$ip (внутренний IP)' : '$ip (private IP)';
    }
    return ip;
  }

  Widget _badge({
    required String text,
    required Color color,
    IconData? icon,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 11, color: color),
            const SizedBox(width: 4),
          ],
          Flexible(
            child: Text(
              text,
              style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthState>();
    final s = context.strings;
    final isRu = auth.isRu;
    final history = auth.history;
    final df = DateFormat('dd.MM.yyyy HH:mm:ss');

    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E293B),
        title: Text(s.historyTitle, style: const TextStyle(color: Colors.white, fontSize: 18)),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: Color(0xFF38BDF8)),
            onPressed: () => auth.loadHistory(),
            tooltip: s.refresh,
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            margin: const EdgeInsets.all(16),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFEF4444).withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.redAccent.withValues(alpha: 0.4)),
            ),
            child: Row(
              children: [
                const Icon(Icons.shield_outlined, color: Colors.redAccent, size: 28),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isRu ? 'Заметили чужой вход?' : 'Notice suspicious login?',
                        style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 13),
                      ),
                      Text(
                        isRu ? 'Нажмите кнопку для экстренного отзыва сессии' : 'Tap button for emergency session revocation',
                        style: const TextStyle(color: Color(0xFFFCA5A5), fontSize: 11),
                      ),
                    ],
                  ),
                ),
                OutlinedButton(
                  onPressed: () => _handleEmergencyRevoke(context),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.redAccent,
                    side: const BorderSide(color: Colors.redAccent),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  ),
                  child: Text(isRu ? 'Это не я' : 'Not me', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          ),
          Expanded(
            child: history.isEmpty
                ? Center(
                    child: Text(isRu ? 'История событий пуста' : 'Event history is empty', style: const TextStyle(color: Color(0xFF64748B))),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    itemCount: history.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (context, index) {
                      final item = history[index];
                      final isSuccess = item['result'] == 'ok';
                      final event = item['event']?.toString() ?? 'auth';
                      final eventTitle = item['event_title']?.toString() ?? _formatEventName(event, isRu);
                      final resultTitle = item['result_title']?.toString() ?? (isSuccess ? s.statusSuccess : s.statusFailed);
                      final service = item['service']?.toString() ?? (isRu ? 'Корпоративный доступ' : 'Corporate Access');
                      final method = item['method']?.toString() ?? (isRu ? 'Пароль / 2FA' : 'Password / 2FA');
                      final clientIp = item['client_ip']?.toString() ?? item['ip']?.toString() ?? '—';
                      final hostIp = item['host_ip']?.toString() ?? '';
                      final device = item['device']?.toString() ?? '';
                      final tsStr = item['timestamp']?.toString();
                      DateTime? ts;
                      if (tsStr != null) {
                        ts = DateTime.tryParse(tsStr)?.toLocal();
                      }

                      Color statusColor = const Color(0xFF10B981);
                      if (!isSuccess || resultTitle.contains('Отклонено') || resultTitle.contains('Ошибка') || resultTitle.contains('Failed') || resultTitle.contains('Rejected')) {
                        statusColor = Colors.redAccent;
                      }

                      return InkWell(
                        onTap: () => _showDetailsDialog(context, item),
                        borderRadius: BorderRadius.circular(12),
                        child: Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: const Color(0xFF1E293B),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: isSuccess
                                  ? const Color(0xFF334155)
                                  : Colors.redAccent.withValues(alpha: 0.3),
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // 1. Верхняя строка: иконка статуса + заголовок + дата
                              Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.all(6),
                                    decoration: BoxDecoration(
                                      color: statusColor.withValues(alpha: 0.15),
                                      shape: BoxShape.circle,
                                    ),
                                    child: Icon(
                                      isSuccess ? Icons.check_circle_outline : Icons.highlight_off,
                                      color: statusColor,
                                      size: 18,
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      eventTitle,
                                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.white),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  if (ts != null)
                                    Text(
                                      df.format(ts),
                                      style: const TextStyle(fontSize: 11, color: Color(0xFF64748B)),
                                    ),
                                ],
                              ),
                              const SizedBox(height: 10),

                              // 2. Бейджи: Сервис («Куда») + Способ («Чем») + Статус
                              Wrap(
                                spacing: 6,
                                runSpacing: 6,
                                children: [
                                  _badge(
                                    text: service,
                                    color: const Color(0xFF38BDF8),
                                    icon: Icons.apps,
                                  ),
                                  _badge(
                                    text: method,
                                    color: const Color(0xFFF59E0B),
                                    icon: Icons.security,
                                  ),
                                  _badge(
                                    text: resultTitle,
                                    color: statusColor,
                                    icon: isSuccess ? Icons.check : Icons.close,
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),

                              // 3. Строка с IP и устройством («Где / Откуда»)
                              Row(
                                children: [
                                  const Icon(Icons.wifi, size: 13, color: Color(0xFF94A3B8)),
                                  const SizedBox(width: 4),
                                  Expanded(
                                    child: Text(
                                      hostIp.isNotEmpty && hostIp != clientIp
                                          ? (isRu
                                              ? 'Клиент: ${_formatIPWithPrivate(clientIp, isRu)} • Сервер: ${_formatIPWithPrivate(hostIp, isRu)}'
                                              : 'Client: ${_formatIPWithPrivate(clientIp, isRu)} • Server: ${_formatIPWithPrivate(hostIp, isRu)}')
                                          : (isRu
                                              ? 'Клиент: ${_formatIPWithPrivate(clientIp, isRu)}'
                                              : 'Client: ${_formatIPWithPrivate(clientIp, isRu)}'),
                                      style: const TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                              if (device.isNotEmpty) ...[
                                const SizedBox(height: 4),
                                Row(
                                  children: [
                                    const Icon(Icons.devices, size: 13, color: Color(0xFF64748B)),
                                    const SizedBox(width: 4),
                                    Expanded(
                                      child: Text(
                                        device,
                                        style: const TextStyle(fontSize: 11, color: Color(0xFF64748B)),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    const Icon(Icons.chevron_right, size: 16, color: Color(0xFF64748B)),
                                  ],
                                ),
                              ],
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  String _formatEventName(String raw, bool isRu) {
    switch (raw) {
      case 'app_login':
        return isRu ? 'Вход в приложение' : 'App Login';
      case 'app_push_decision':
        return isRu ? 'Подтверждение 2FA входа' : '2FA Push Approval';
      case 'tg_push':
        return isRu ? 'Вход через Telegram' : 'Login via Telegram';
      case 'login_ok':
        return isRu ? 'Успешный вход в систему' : 'Successful Login';
      case 'login_fail':
        return isRu ? 'Неудачная попытка входа' : 'Failed Login Attempt';
      case 'code_sent':
        return isRu ? 'Отправлен одноразовый код' : 'One-Time Code Sent';
      case 'code_fail':
        return isRu ? 'Неверный 2FA код' : 'Invalid 2FA Code';
      case 'radius_auth':
        return isRu ? 'Авторизация в сети Wi-Fi/VPN' : 'Wi-Fi / VPN Authorization';
      case 'oidc_token':
        return isRu ? 'Вход через SSO (OpenID)' : 'Login via SSO (OpenID)';
      case 'oidc_consent':
        return isRu ? 'Предоставление доступа SSO' : 'SSO Consent Granted';
      case 'api_start':
        return isRu ? 'Запрос 2FA входа' : '2FA Login Request';
      case 'api_verify_ok':
        return isRu ? 'Успешная 2FA авторизация' : 'Successful 2FA Authorization';
      default:
        return raw;
    }
  }
}
