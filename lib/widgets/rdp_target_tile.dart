import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../i18n/app_strings.dart';

/// Плитка RDP-цели «Мой ПК»: современная премиальная тёмная карточка
/// с мягким неоновым свечением, аккуратными градиентами, чёткой типографикой
/// и адаптивными кнопками действий без обрезания текста ("Под...").
class RdpTargetTile extends StatelessWidget {
  const RdpTargetTile({
    super.key,
    required this.target,
    required this.isRu,
    this.onConnect,
    this.onScreen,
    this.connecting = false,
    this.margin,
  });

  final Map<String, dynamic> target;
  final bool isRu;
  final VoidCallback? onConnect;
  final VoidCallback? onScreen;
  final bool connecting;
  final EdgeInsetsGeometry? margin;

  static bool get canLaunchRdp =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.macOS);

  @override
  Widget build(BuildContext context) {
    final s = context.stringsRead;
    final name = target['name']?.toString() ?? '';
    final kind = target['kind']?.toString() ?? 'pc';
    final isTs = kind == 'terminal_server' || kind == 'ts';
    final maxSessions = int.tryParse(target['max_sessions']?.toString() ?? '') ?? 1;
    final online = target['online'] == true;
    final endpoint = target['endpoint']?.toString() ?? '';
    final route = target['route']?.toString() ?? '';
    final screenAvailable = target['screen_available'] == true;
    final screenReason = target['screen_reason']?.toString() ?? '';
    final isSelf = target['is_self'] == true;
    final rdpAvailable = target['rdp_available'] != false;
    final rdpReason = target['rdp_reason']?.toString() ?? '';

    final isServer = isTs || route == 'direct' || route == 'relay';
    final effectiveOnline = isServer ? true : online;

    return Container(
      margin: margin ?? const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF131B2B),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.08),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // Верхняя часть: Иконка + Имя + Бейджи
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: isTs
                        ? [const Color(0xFFF59E0B).withValues(alpha: 0.18), const Color(0xFFB45309).withValues(alpha: 0.08)]
                        : [const Color(0xFF0284C7).withValues(alpha: 0.22), const Color(0xFF0369A1).withValues(alpha: 0.06)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: isTs
                        ? const Color(0xFFF59E0B).withValues(alpha: 0.35)
                        : const Color(0xFF38BDF8).withValues(alpha: 0.35),
                    width: 1,
                  ),
                ),
                child: Icon(
                  isTs ? Icons.dns_rounded : Icons.desktop_windows_rounded,
                  size: 22,
                  color: isTs ? const Color(0xFFFBBF24) : const Color(0xFF38BDF8),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        // Неоновый индикатор статуса
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: effectiveOnline ? const Color(0xFF10B981) : const Color(0xFF64748B),
                            boxShadow: effectiveOnline
                                ? [
                                    BoxShadow(
                                      color: const Color(0xFF10B981).withValues(alpha: 0.6),
                                      blurRadius: 6,
                                      spreadRadius: 1,
                                    ),
                                  ]
                                : null,
                          ),
                        ),
                        const SizedBox(width: 7),
                        Expanded(
                          child: Text(
                            name,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.2,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 5),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        // Бейдж типа устройства
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            color: (isTs ? const Color(0xFFF59E0B) : const Color(0xFF0284C7))
                                .withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color: (isTs ? const Color(0xFFF59E0B) : const Color(0xFF0284C7))
                                  .withValues(alpha: 0.3),
                              width: 0.8,
                            ),
                          ),
                          child: Text(
                            isTs ? s.rdpKindTerminal : s.rdpKindPc,
                            style: TextStyle(
                              color: isTs ? const Color(0xFFFBBF24) : const Color(0xFF38BDF8),
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (isSelf)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.06),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
                            ),
                            child: Text(
                              s.rdpSelfBadge,
                              style: const TextStyle(
                                color: Color(0xFF94A3B8),
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        if (isTs && maxSessions > 1)
                          Text(
                            s.rdpParallelSessions(maxSessions),
                            style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 10),
                            overflow: TextOverflow.ellipsis,
                          ),
                        if (route.isNotEmpty)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.04),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              route,
                              style: const TextStyle(
                                color: Color(0xFF64748B),
                                fontSize: 9,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0.2,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),

          if (endpoint.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6, bottom: 2),
              child: Text(
                endpoint,
                style: const TextStyle(color: Color(0xFF64748B), fontSize: 11),
                overflow: TextOverflow.ellipsis,
              ),
            ),

          const SizedBox(height: 10),

          // Нижняя часть: Кнопки действий
          if (isTs) ...[
            SizedBox(
              width: double.infinity,
              height: 38,
              child: _connectControl(s, online, isSelf, rdpAvailable, rdpReason, route, isTs),
            ),
          ] else ...[
            SizedBox(
              height: 38,
              child: Row(
                children: [
                  Expanded(
                    child: _connectControl(s, online, isSelf, rdpAvailable, rdpReason, route, isTs),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _screenControl(context, s, screenAvailable, screenReason),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _screenControl(BuildContext context, AppStrings s, bool screenAvailable, String screenReason) {
    String tooltipMessage = '';
    if (!screenAvailable) {
      if (screenReason == 'screen_device_unbound') {
        tooltipMessage = isRu
            ? 'Целевой ПК не привязан к устройству'
            : 'Target PC is not bound to a device';
      } else if (screenReason == 'self_connection_prohibited') {
        tooltipMessage = isRu
            ? 'Трансляция экрана на текущем ПК недоступна'
            : 'Screen sharing on current PC is unavailable';
      } else if (screenReason == 'sharer_not_running') {
        tooltipMessage = isRu
            ? 'ПК заблокирован или не залогинен (используйте RDP)'
            : 'PC is locked or not logged in (use RDP)';
      } else {
        tooltipMessage = isRu
            ? 'Режим экрана недоступен'
            : 'Screen mode is unavailable';
      }
    }

    final btn = Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: screenAvailable
            ? onScreen
            : () {
                final msg = screenReason == 'sharer_not_running'
                    ? (isRu
                        ? 'ПК заблокирован или сеанс не начат. Для входа используйте кнопку «Подключить» (RDP).'
                        : 'PC is locked or user not logged in. Use the "Connect" (RDP) button to access.')
                    : tooltipMessage;
                if (msg.isNotEmpty) {
                  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                    SnackBar(
                      content: Text(msg),
                      duration: const Duration(seconds: 4),
                      behavior: SnackBarBehavior.floating,
                      backgroundColor: const Color(0xFF1E293B),
                    ),
                  );
                }
              },
        borderRadius: BorderRadius.circular(10),
        child: Ink(
          decoration: BoxDecoration(
            color: screenAvailable
                ? const Color(0xFF0284C7).withValues(alpha: 0.12)
                : const Color(0xFF0F172A).withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: screenAvailable
                  ? const Color(0xFF0284C7).withValues(alpha: 0.5)
                  : Colors.white.withValues(alpha: 0.06),
              width: 1,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.monitor_rounded,
                size: 15,
                color: screenAvailable ? const Color(0xFF38BDF8) : const Color(0xFF64748B),
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  s.rdpScreenBtn,
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: screenAvailable ? const Color(0xFF38BDF8) : const Color(0xFF64748B),
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );

    if (!screenAvailable) {
      return Tooltip(message: tooltipMessage, child: btn);
    }
    return btn;
  }

  /// Кнопка подключения:
  /// - Для Terminal Server (полная ширина): "Подключиться"
  /// - Для ПК (делит строку с «Экран»): "Подключить" (никогда не обрезается в "Под...")
  Widget _connectControl(AppStrings s, bool online, bool isSelf, bool rdpAvailable, String rdpReason, String route, bool isTs) {
    if (!canLaunchRdp) {
      return Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: const Color(0xFF0F172A).withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
        ),
        child: Text(
          isRu ? 'RDP — Windows / macOS' : 'RDP — Windows / macOS',
          maxLines: 1,
          style: const TextStyle(color: Color(0xFF64748B), fontSize: 10),
          overflow: TextOverflow.ellipsis,
        ),
      );
    }
    if (isSelf || rdpReason == 'self_connection_prohibited') {
      return Tooltip(
        message: s.rdpSelfProhibited,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: const Color(0xFF0F172A).withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
          ),
          child: Text(
            s.rdpSelfBtn,
            maxLines: 1,
            style: const TextStyle(color: Color(0xFF64748B), fontSize: 11),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      );
    }
    final isServer = isTs || route == 'direct' || route == 'relay';
    if (isServer && (!online || !rdpAvailable)) {
      return Tooltip(
        message: s.rdpServerOfflineHint,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: const Color(0xFF0F172A).withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
          ),
          child: Text(
            s.rdpServerOffline,
            maxLines: 1,
            style: const TextStyle(color: Color(0xFF64748B), fontSize: 11),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      );
    }
    if (!isServer && (!online || !rdpAvailable)) {
      return Tooltip(
        message: s.rdpOfflineHint,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: const Color(0xFF0F172A).withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
          ),
          child: Text(
            s.rdpServiceOffline,
            maxLines: 1,
            style: const TextStyle(color: Color(0xFF64748B), fontSize: 11),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      );
    }
    if (rdpReason == 'target_disabled' || target['enabled'] == false) {
      return Tooltip(
        message: isRu ? 'Цель отключена администратором' : 'Target disabled by admin',
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: const Color(0xFF0F172A).withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
          ),
          child: Text(
            isRu ? 'Отключено' : 'Disabled',
            maxLines: 1,
            style: const TextStyle(color: Color(0xFF64748B), fontSize: 11),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      );
    }

    final btnLabel = isTs
        ? s.rdpConnectBtn
        : (isRu ? 'Подключить' : 'Connect');

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: connecting ? null : onConnect,
        borderRadius: BorderRadius.circular(10),
        child: Ink(
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFF059669), Color(0xFF10B981)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: const Color(0xFF34D399).withValues(alpha: 0.35),
              width: 1,
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF059669).withValues(alpha: 0.3),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (connecting)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                  ),
                )
              else
                const Icon(
                  Icons.bolt_rounded,
                  size: 16,
                  color: Colors.white,
                ),
              const SizedBox(width: 5),
              Flexible(
                child: Text(
                  btnLabel,
                  maxLines: 1,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                    letterSpacing: -0.1,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
