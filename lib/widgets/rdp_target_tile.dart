import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../i18n/app_strings.dart';

/// Плитка RDP-цели «Мой ПК» (этап 2.1, план §2.3-2.4): тёмная карточка в
/// стиле AppsScreen (фон 0xFF1E293B, радиус 16), крупная иконка ПК, имя,
/// чип типа (pc / terminal_server), строка endpoint, онлайн-индикатор
/// (зелёная/серая точка + route) и кнопки действий.
///
/// - «Подключиться» — только Windows и !kIsWeb (этап 2.2, mstsc); offline
///   заменяет кнопку на неактивную «Служба Ligament offline» (дизайн §10.1);
/// - «Экран» — все платформы, этап 2b (сейчас заглушка-подсказка);
/// - терминальный сервер — подпись «N параллельных сессий»;
/// - место под будущий скрин capabilities (S2) оставлено: leading-иконка
///   заменяется на Image.network без изменения layout.
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

  static bool get canLaunchRdp => !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  @override
  Widget build(BuildContext context) {
    final s = context.stringsRead;
    final name = target['name']?.toString() ?? '';
    final kind = target['kind']?.toString() ?? 'pc';
    final isTs = kind == 'terminal_server';
    final maxSessions = int.tryParse(target['max_sessions']?.toString() ?? '') ?? 1;
    final online = target['online'] == true;
    final endpoint = target['endpoint']?.toString() ?? '';
    final route = target['route']?.toString() ?? '';

    return Container(
      margin: margin ?? const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
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
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFF0F172A),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.desktop_windows_outlined,
                  size: 26,
                  color: Color(0xFF38BDF8),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        // Онлайн-индикатор цели: agent — живой агент службы;
                        // relay/direct считаются доступными всегда (§1.1).
                        Container(
                          width: 9,
                          height: 9,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: online ? const Color(0xFF10B981) : const Color(0xFF64748B),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            name,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: (isTs ? const Color(0xFFF59E0B) : const Color(0xFF0284C7))
                                .withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            isTs ? s.rdpKindTerminal : s.rdpKindPc,
                            style: TextStyle(
                              color: isTs ? const Color(0xFFFBBF24) : const Color(0xFF38BDF8),
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        if (isTs && maxSessions > 1) ...[
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              s.rdpParallelSessions(maxSessions),
                              style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 10),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                        if (route.isNotEmpty) ...[
                          const SizedBox(width: 6),
                          // Мобильная адаптация (390px): маршрут — гибкий,
                          // длинный relay-маршрут обрезается многоточием,
                          // а не переполняет строку чипов.
                          Flexible(
                            child: Text(
                              '· $route',
                              maxLines: 1,
                              style: const TextStyle(
                                color: Color(0xFF64748B),
                                fontSize: 10,
                                fontStyle: FontStyle.italic,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (endpoint.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              endpoint,
              style: const TextStyle(color: Color(0xFF64748B), fontSize: 11),
              overflow: TextOverflow.ellipsis,
            ),
          ],
          const SizedBox(height: 12),
          // Мобильная адаптация (390px): две кнопки на всю ширину плитки,
          // подписи — в одну строку с многоточием, компактный горизонтальный
          // padding кнопок (умещаются «Подключиться» + «Экран» рядом).
          Row(
            children: [
              Expanded(
                child: _connectControl(s, online),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: onScreen,
                  icon: const Icon(Icons.monitor_outlined, size: 16),
                  label: Text(
                    s.rdpScreenBtn,
                    maxLines: 1,
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                    overflow: TextOverflow.ellipsis,
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF38BDF8),
                    side: const BorderSide(color: Color(0xFF0284C7)),
                    padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Кнопка подключения: Windows+online → «Подключиться»; offline →
  /// неактивная «Служба Ligament offline»; прочие платформы → подсказка
  /// этапа 2b (кнопка «Экран» справа остаётся главной). Все варианты —
  /// в одну строку с многоточием: ширина ячейки на 390px ≈ 160px.
  Widget _connectControl(AppStrings s, bool online) {
    if (!canLaunchRdp) {
      return Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        alignment: Alignment.center,
        child: Text(
          isRu ? 'RDP — только Windows' : 'RDP — Windows only',
          maxLines: 1,
          style: const TextStyle(color: Color(0xFF64748B), fontSize: 10),
          overflow: TextOverflow.ellipsis,
        ),
      );
    }
    if (!online) {
      return Tooltip(
        message: s.rdpOfflineHint,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: const Color(0xFF0F172A),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0xFF334155)),
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
    return ElevatedButton.icon(
      onPressed: connecting ? null : onConnect,
      icon: connecting
          ? const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
            )
          : const Icon(Icons.terminal_outlined, size: 16),
      label: Text(
        s.rdpConnectBtn,
        maxLines: 1,
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
        overflow: TextOverflow.ellipsis,
      ),
      style: ElevatedButton.styleFrom(
        backgroundColor: const Color(0xFF10B981),
        foregroundColor: Colors.white,
        disabledBackgroundColor: const Color(0xFF065F46),
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }
}
