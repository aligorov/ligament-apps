import 'package:flutter/material.dart';

import '../i18n/app_strings.dart';
import '../services/rdp_service.dart';

/// Диалог статуса RDP-подключения (этап 2.2, план §3.1): шаги
/// «Грант… → Слушатель… → Туннель… → Запуск mstsc», спиннер, кнопка
/// «Отменить»; ошибки — человеческим текстом (428/403/409/410/502/503
/// мапятся в rdpConnectErrorText). Диалог живёт, пока коннектор не станет
/// active (закрывается сам, туннель продолжает работать) или failed.
class RdpConnectDialog extends StatelessWidget {
  const RdpConnectDialog({super.key, required this.connector, required this.targetName});

  final RdpConnectorService connector;
  final String targetName;

  @override
  Widget build(BuildContext context) {
    final s = context.strings;
    return ListenableBuilder(
      listenable: connector,
      builder: (context, _) {
        final phase = connector.phase;
        final done = phase == RdpTunnelPhase.active || phase == RdpTunnelPhase.closed || phase == RdpTunnelPhase.idle;
        final failed = phase == RdpTunnelPhase.failed;

        // Сессия установлена — закрываем диалог (туннель живёт в фоне,
        // баннер активной сессии остаётся на главной).
        if (done) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (Navigator.of(context).canPop()) {
              Navigator.of(context).pop(true);
            }
          });
        }

        // Мобильная адаптация (390px): дефолтные 40px inset с каждой стороны
        // съедали четверть ширины — тексты шагов переносились раньше времени;
        // контент — прокручиваемый: длинная ошибка сервера не переполняет
        // экран по вертикали.
        return AlertDialog(
          backgroundColor: const Color(0xFF0F172A),
          insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: Color(0xFF334155)),
          ),
          title: Row(
            children: [
              Icon(
                failed ? Icons.error_outline : Icons.desktop_windows_outlined,
                color: failed ? const Color(0xFFEF4444) : const Color(0xFF38BDF8),
                size: 22,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  failed ? s.error : s.rdpConnTitle,
                  style: const TextStyle(color: Colors.white, fontSize: 16),
                ),
              ),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  targetName,
                  maxLines: 1,
                  style: const TextStyle(
                    color: Color(0xFF94A3B8),
                    fontSize: 12,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 16),
                if (failed)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.error_outline, color: Color(0xFFEF4444), size: 20),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          connector.lastError ?? '',
                          style: const TextStyle(color: Color(0xFFFCA5A5), fontSize: 13),
                        ),
                      ),
                    ],
                  )
                else ...[
                  const SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(strokeWidth: 3, color: Color(0xFF38BDF8)),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    _stepText(s, phase, connector.phaseDetail),
                    style: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 13),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            if (failed)
              ElevatedButton(
                onPressed: () => Navigator.of(context).pop(false),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF2563EB),
                  foregroundColor: Colors.white,
                ),
                child: Text(s.close),
              )
            else
              TextButton(
                onPressed: () {
                  connector.close(isRu: s.isRu);
                  Navigator.of(context).pop(false);
                },
                child: Text(s.cancel),
              ),
          ],
        );
      },
    );
  }

  String _stepText(AppStrings s, RdpTunnelPhase phase, String? detail) {
    switch (phase) {
      case RdpTunnelPhase.grant:
        return s.rdpStepGrant;
      case RdpTunnelPhase.listener:
        return s.rdpStepListener;
      case RdpTunnelPhase.tunnel:
        return s.rdpStepTunnel;
      case RdpTunnelPhase.launching:
        return s.rdpStepLaunch;
      case RdpTunnelPhase.waitingClient:
        return s.rdpStepWaitingClient;
      case RdpTunnelPhase.active:
        return s.rdpStepActive;
      default:
        return s.rdpStepGrant;
    }
  }
}
