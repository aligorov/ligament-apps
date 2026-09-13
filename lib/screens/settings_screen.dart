import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/auth_state.dart';
import '../i18n/app_strings.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthState>();
    final s = context.strings;
    final user = auth.currentUser ?? {};
    final posture = auth.currentPosture ?? {};
    final isGpoLocked = auth.gpo.enforcedServerUrl != null;
    final allowExit = auth.gpo.allowExit;
    final isMac = !kIsWeb && Platform.isMacOS;
    final isWin = !kIsWeb && Platform.isWindows;
    final isLin = !kIsWeb && Platform.isLinux;

    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E293B),
        title: Text(s.settingsTitle, style: const TextStyle(color: Colors.white, fontSize: 18)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Карточка пользователя
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF1E293B),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFF334155)),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFF38BDF8).withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.person, color: Color(0xFF38BDF8), size: 32),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        user['display_name'] ?? user['username'] ?? s.userFallback,
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.white),
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Text(
                            s.userRole(user['role']?.toString() ?? 'user'),
                            style: const TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
                          ),
                          if (auth.engineerBadge != null) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                              decoration: BoxDecoration(
                                color: const Color(0xFF38BDF8).withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                auth.engineerBadge!,
                                style: const TextStyle(color: Color(0xFF38BDF8), fontSize: 10, fontWeight: FontWeight.bold),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        s.serverUrl(auth.serverUrl ?? '—'),
                        style: const TextStyle(fontSize: 11, color: Color(0xFF64748B)),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Карточка факторов защиты 2FA
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF1E293B),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFF334155)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.shield_outlined, color: Color(0xFF38BDF8), size: 20),
                    const SizedBox(width: 8),
                    Text(
                      s.security2FASection,
                      style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 14),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _statusTile(
                  s.totpAppStatus,
                  user['totp_linked'] == true ? s.configuredOk : s.notConfigured,
                  user['totp_linked'] == true ? Colors.greenAccent : Colors.grey,
                ),
                _statusTile(
                  s.backupCodesStatus,
                  '${user['backup_remaining'] ?? 0} шт.',
                  (user['backup_remaining'] is int && (user['backup_remaining'] as int) > 0) ? Colors.greenAccent : Colors.amber,
                ),
                _statusTile(
                  s.passkeysStatus,
                  '${user['passkey_count'] ?? 0} шт.',
                  (user['passkey_count'] is int && (user['passkey_count'] as int) > 0) ? Colors.greenAccent : Colors.grey,
                ),
                _statusTile(
                  s.telegramStatus,
                  user['telegram_bound'] == true ? s.configuredOk : s.notConfigured,
                  user['telegram_bound'] == true ? Colors.greenAccent : Colors.grey,
                ),
                if (auth.serverUrl != null && auth.serverUrl!.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () {
                        final uri = Uri.parse('${auth.serverUrl}/me');
                        launchUrl(uri, mode: LaunchMode.externalApplication);
                      },
                      icon: const Icon(Icons.open_in_new, size: 16),
                      label: Text(s.webCabinetButton, style: const TextStyle(fontSize: 12)),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF38BDF8),
                        side: const BorderSide(color: Color(0xFF38BDF8)),
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Карточка настроек уведомлений
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF1E293B),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFF334155)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.notifications_active_outlined, color: Color(0xFF38BDF8), size: 20),
                    const SizedBox(width: 8),
                    Text(
                      s.notificationsSection,
                      style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 14),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _switchTile(
                  title: s.notifyLoginSuccess,
                  subtitle: auth.isRu ? 'Оповещать при входе с любого устройства' : 'Alert on login from any device',
                  value: auth.notificationSettings['login_success'] != false,
                  onChanged: (val) {
                    final curr = auth.notificationSettings;
                    auth.updateNotificationSettings(
                      loginSuccess: val,
                      loginDenied: curr['login_denied'] != false,
                      notifyTG: curr['notify_tg'] != false,
                      notifyEmail: curr['notify_email'] != false,
                    );
                  },
                ),
                _switchTile(
                  title: s.notifyLoginDenied,
                  subtitle: auth.isRu ? 'Оповещать об отклоненных попытках' : 'Alert on blocked / denied attempts',
                  value: auth.notificationSettings['login_denied'] != false,
                  onChanged: (val) {
                    final curr = auth.notificationSettings;
                    auth.updateNotificationSettings(
                      loginSuccess: curr['login_success'] != false,
                      loginDenied: val,
                      notifyTG: curr['notify_tg'] != false,
                      notifyEmail: curr['notify_email'] != false,
                    );
                  },
                ),
                const Divider(color: Color(0xFF334155), height: 20),
                _switchTile(
                  title: s.notifyViaTelegram,
                  subtitle: user['telegram_bound'] == true
                      ? (auth.isRu ? 'Канал подключен' : 'Channel connected')
                      : (auth.isRu ? 'Telegram не привязан' : 'Telegram not linked'),
                  value: auth.notificationSettings['notify_tg'] != false,
                  onChanged: (val) {
                    final curr = auth.notificationSettings;
                    auth.updateNotificationSettings(
                      loginSuccess: curr['login_success'] != false,
                      loginDenied: curr['login_denied'] != false,
                      notifyTG: val,
                      notifyEmail: curr['notify_email'] != false,
                    );
                  },
                ),
                _switchTile(
                  title: s.notifyViaEmail,
                  subtitle: (user['email'] != null && user['email'].toString().isNotEmpty)
                      ? user['email'].toString()
                      : (auth.isRu ? 'Email не указан' : 'Email not specified'),
                  value: auth.notificationSettings['notify_email'] != false,
                  onChanged: (val) {
                    final curr = auth.notificationSettings;
                    auth.updateNotificationSettings(
                      loginSuccess: curr['login_success'] != false,
                      loginDenied: curr['login_denied'] != false,
                      notifyTG: curr['notify_tg'] != false,
                      notifyEmail: val,
                    );
                  },
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () => _handleTestDelivery(context, auth, s),
                    icon: const Icon(Icons.send_outlined, size: 16),
                    label: Text(s.testDeliveryButton, style: const TextStyle(fontSize: 13)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF38BDF8).withValues(alpha: 0.18),
                      foregroundColor: const Color(0xFF38BDF8),
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                        side: const BorderSide(color: Color(0xFF38BDF8)),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Карточка переключения языка интерфейса
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF1E293B),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFF334155)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.language_outlined, color: Color(0xFF38BDF8), size: 20),
                    const SizedBox(width: 8),
                    Text(
                      s.languageSection,
                      style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 14),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: InkWell(
                        borderRadius: BorderRadius.circular(10),
                        onTap: () => auth.setLocale('ru'),
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
                          decoration: BoxDecoration(
                            color: auth.isRu ? const Color(0xFF38BDF8).withValues(alpha: 0.18) : Colors.transparent,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: auth.isRu ? const Color(0xFF38BDF8) : const Color(0xFF334155),
                              width: auth.isRu ? 1.5 : 1.0,
                            ),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Text('🇷🇺', style: TextStyle(fontSize: 18)),
                              const SizedBox(width: 8),
                              Text(
                                s.languageRussian,
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: auth.isRu ? FontWeight.bold : FontWeight.normal,
                                  color: auth.isRu ? Colors.white : const Color(0xFF94A3B8),
                                ),
                              ),
                              if (auth.isRu) ...[
                                const SizedBox(width: 6),
                                const Icon(Icons.check, size: 16, color: Color(0xFF38BDF8)),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: InkWell(
                        borderRadius: BorderRadius.circular(10),
                        onTap: () => auth.setLocale('en'),
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
                          decoration: BoxDecoration(
                            color: !auth.isRu ? const Color(0xFF38BDF8).withValues(alpha: 0.18) : Colors.transparent,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: !auth.isRu ? const Color(0xFF38BDF8) : const Color(0xFF334155),
                              width: !auth.isRu ? 1.5 : 1.0,
                            ),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Text('🇬🇧', style: TextStyle(fontSize: 18)),
                              const SizedBox(width: 8),
                              Text(
                                s.languageEnglish,
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: !auth.isRu ? FontWeight.bold : FontWeight.normal,
                                  color: !auth.isRu ? Colors.white : const Color(0xFF94A3B8),
                                ),
                              ),
                              if (!auth.isRu) ...[
                                const SizedBox(width: 6),
                                const Icon(Icons.check, size: 16, color: Color(0xFF38BDF8)),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Карточка филиальных узлов Relay
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF1E293B),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFF334155)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.hub_outlined, color: Color(0xFF38BDF8), size: 20),
                        const SizedBox(width: 8),
                        Text(
                          s.branchRelaysSection,
                          style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 14),
                        ),
                      ],
                    ),
                    IconButton(
                      icon: const Icon(Icons.refresh, size: 18, color: Color(0xFF38BDF8)),
                      onPressed: () => auth.refreshRelays(),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  s.branchRelaysSubtitle,
                  style: const TextStyle(color: Color(0xFF64748B), fontSize: 11),
                ),
                const SizedBox(height: 12),
                if (auth.relays.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      s.noBranchRelays,
                      style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
                    ),
                  )
                else
                  ...auth.relays.map((relay) {
                    final ip = relay['last_ip']?.toString() ?? '—';
                    final name = relay['name']?.toString() ?? 'Relay';
                    final isCurrent = auth.activeRelayEndpoint == ip;
                    return Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0F172A),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: isCurrent ? const Color(0xFF38BDF8) : const Color(0xFF334155),
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.router,
                            size: 20,
                            color: isCurrent ? const Color(0xFF38BDF8) : const Color(0xFF94A3B8),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  name,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  'LAN IP: $ip:8082',
                                  style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 11),
                                ),
                              ],
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: isCurrent
                                  ? const Color(0xFF0284C7).withValues(alpha: 0.2)
                                  : const Color(0xFF334155),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              isCurrent ? s.relayActiveGateway : s.relayStandbyGateway,
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                color: isCurrent ? const Color(0xFF38BDF8) : const Color(0xFF94A3B8),
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  }),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Карточка централизованных политик (GPO для Windows / MDM для macOS)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF1E293B),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFF334155)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.policy_outlined, color: Color(0xFF38BDF8), size: 20),
                    const SizedBox(width: 8),
                    Text(
                      isMac ? s.gpoMac : (isWin ? s.gpoWin : s.gpoCorp),
                      style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 14),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _statusTile(
                  s.centralManagement,
                  isGpoLocked ? (isMac ? s.activeMdm : s.activeGpo) : s.notAssigned,
                  isGpoLocked ? Colors.greenAccent : Colors.grey,
                ),
                _statusTile(
                  isMac ? s.reqTouchId : s.reqWinHello,
                  auth.gpo.requireWindowsHello ? s.enabled : s.disabled,
                  auth.gpo.requireWindowsHello ? Colors.greenAccent : Colors.grey,
                ),
                _statusTile(
                  isMac ? s.reqFileVault : s.reqBitLocker,
                  auth.gpo.requireBitLocker ? s.enabled : s.disabled,
                  auth.gpo.requireBitLocker ? Colors.greenAccent : Colors.grey,
                ),
                _statusTile(
                  s.appExit,
                  allowExit ? s.allowed : s.blockedByPolicy,
                  allowExit ? Colors.grey : Colors.amber,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Карточка телеметрии устройства
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF1E293B),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFF334155)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.health_and_safety_outlined, color: Color(0xFF10B981), size: 20),
                        const SizedBox(width: 8),
                        Text(s.securityTelemetry, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 14)),
                      ],
                    ),
                    IconButton(
                      icon: const Icon(Icons.refresh, size: 18, color: Color(0xFF38BDF8)),
                      onPressed: () => auth.checkPosture(),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                _statusTile(
                  s.complianceStatus,
                  auth.isCompliant ? s.compliant : s.nonCompliant,
                  auth.isCompliant ? Colors.greenAccent : Colors.redAccent,
                ),

                // macOS специфичные бейджи
                if (isMac) ...[
                  if (posture['filevault'] != null)
                    _statusTile(
                      s.fileVaultEnc,
                      posture['filevault'] == 'encrypted' ? s.fileVaultOn : s.disabled,
                      posture['filevault'] == 'encrypted' ? Colors.greenAccent : Colors.redAccent,
                    ),
                  if (posture['gatekeeper'] != null)
                    _statusTile(
                      s.gatekeeper,
                      posture['gatekeeper'] == 'active' ? s.active : s.disabled,
                      posture['gatekeeper'] == 'active' ? Colors.greenAccent : Colors.redAccent,
                    ),
                  if (posture['firewall'] != null)
                    _statusTile(
                      s.macosFirewall,
                      posture['firewall'] == 'active' ? s.enabled : s.disabled,
                      posture['firewall'] == 'active' ? Colors.greenAccent : Colors.redAccent,
                    ),
                  if (posture['touch_id'] != null)
                    _statusTile(
                      s.touchId,
                      posture['touch_id'] == true ? s.touchIdAvailable : s.touchIdNotConfigured,
                      posture['touch_id'] == true ? Colors.greenAccent : Colors.grey,
                    ),
                ],

                // Windows специфичные бейджи
                if (isWin) ...[
                  if (posture['bitlocker'] != null)
                    _statusTile(
                      s.bitLockerEnc,
                      posture['bitlocker'] == 'encrypted' ? s.bitLockerProtected : s.disabled,
                      posture['bitlocker'] == 'encrypted' ? Colors.greenAccent : Colors.redAccent,
                    ),
                  if (posture['defender'] != null)
                    _statusTile(
                      s.defender,
                      posture['defender'] == 'active' ? s.active : s.disabled,
                      posture['defender'] == 'active' ? Colors.greenAccent : Colors.redAccent,
                    ),
                  if (posture['firewall'] != null)
                    _statusTile(
                      s.winFirewall,
                      posture['firewall'] == 'active' ? s.enabled : s.disabled,
                      posture['firewall'] == 'active' ? Colors.greenAccent : Colors.redAccent,
                    ),
                ],

                // Linux специфичные бейджи
                if (isLin) ...[
                  if (posture['firewall'] != null)
                    _statusTile(
                      s.linuxFirewall,
                      posture['firewall'] == 'active' ? s.enabled : s.disabled,
                      posture['firewall'] == 'active' ? Colors.greenAccent : Colors.redAccent,
                    ),
                ],

                // Мобильные платформы
                if (posture['rooted'] != null)
                  _statusTile(
                    s.rootJailbreak,
                    posture['rooted'] == true ? s.rootDetected : s.rootClean,
                    posture['rooted'] == true ? Colors.redAccent : Colors.greenAccent,
                  ),

                // Метрики ресурсов диска и CPU
                if (posture['disk_details'] != null && posture['disk_details'].toString().isNotEmpty)
                  _statusTile(
                    s.storageDisk,
                    posture['disk_details'].toString(),
                    posture['disk_warning'] == true ? Colors.redAccent : Colors.greenAccent,
                  ),
                if (posture['cpu_percent'] != null)
                  _statusTile(
                    s.cpuLoad,
                    '${posture['cpu_percent']}%',
                    posture['cpu_warning'] == true ? Colors.redAccent : Colors.greenAccent,
                  ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // Кнопка выхода
          ElevatedButton.icon(
            onPressed: allowExit ? () => auth.logout() : null,
            icon: const Icon(Icons.logout),
            label: Text(allowExit ? s.logoutAccount : s.logoutBlocked),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent.withValues(alpha: 0.8),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
          const SizedBox(height: 24),

          // Футер с версией приложения
          Center(
            child: Column(
              children: [
                const Text(
                  'Ligament 2FA v1.0.1+7 (v0.4.49)',
                  style: TextStyle(color: Color(0xFF64748B), fontSize: 12, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                Text(
                  s.platformCorporate(isMac ? "macOS" : (isWin ? "Windows" : (isLin ? "Linux" : "Mobile"))),
                  style: const TextStyle(color: Color(0xFF475569), fontSize: 11),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _statusTile(String title, String value, Color color) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Text(title, style: const TextStyle(fontSize: 13, color: Color(0xFF94A3B8))),
          ),
          Text(value, style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: color)),
        ],
      ),
    );
  }

  Widget _switchTile({
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.white)),
                const SizedBox(height: 2),
                Text(subtitle, style: const TextStyle(fontSize: 11, color: Color(0xFF94A3B8))),
              ],
            ),
          ),
          Switch(
            value: value,
            activeThumbColor: const Color(0xFF38BDF8),
            activeTrackColor: const Color(0xFF0284C7).withValues(alpha: 0.5),
            inactiveThumbColor: const Color(0xFF94A3B8),
            inactiveTrackColor: const Color(0xFF334155),
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }

  Future<void> _handleTestDelivery(BuildContext context, AuthState auth, AppStrings s) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => Center(
        child: Card(
          color: const Color(0xFF1E293B),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(color: Color(0xFF38BDF8)),
                const SizedBox(height: 16),
                Text(s.testDeliveryRunning, style: const TextStyle(color: Colors.white)),
              ],
            ),
          ),
        ),
      ),
    );

    try {
      final results = await auth.testNotificationDelivery();
      if (context.mounted) {
        Navigator.of(context).pop(); // закрываем лоадер
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF1E293B),
            title: Row(
              children: [
                const Icon(Icons.mark_email_read_outlined, color: Color(0xFF38BDF8)),
                const SizedBox(width: 8),
                Text(s.testDeliveryTitle, style: const TextStyle(color: Colors.white, fontSize: 16)),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: results.map((r) {
                final ok = r['success'] == true;
                return Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: (ok ? Colors.green : Colors.red).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: (ok ? Colors.green : Colors.red).withValues(alpha: 0.4)),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(ok ? Icons.check_circle : Icons.error, color: ok ? Colors.greenAccent : Colors.redAccent, size: 20),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('${r['channel']} • ${r['target']}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
                            const SizedBox(height: 2),
                            Text('${r['message']}', style: TextStyle(color: ok ? Colors.greenAccent : Colors.redAccent, fontSize: 11)),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              }).toList(),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: Text(s.ok, style: const TextStyle(color: Color(0xFF38BDF8))),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        Navigator.of(context).pop(); // закрываем лоадер
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Ошибка: $e'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }
}
