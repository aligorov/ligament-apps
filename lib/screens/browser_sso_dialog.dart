import 'package:flutter/material.dart';

import '../i18n/app_strings.dart';

/// Диалог подтверждения browser_sso-челленджа (фаза 2b, SSO-мост):
/// «Вход в {SP} — подтвердить как CORP\ivanov?».
///
/// Чистая презентация: [ready] = есть живый билет И машина совпала —
/// только тогда активна кнопка «Войти»; иначе подсказка про свежий вход в
/// Windows. Решение (approve с билетом / deny без) отправляет AuthState
/// через колбэк [onDecision].
class BrowserSsoDialog extends StatelessWidget {
  const BrowserSsoDialog({
    super.key,
    required this.spName,
    required this.identityDisplay,
    required this.ready,
    required this.onDecision,
  });

  final String spName;
  final String identityDisplay;
  final bool ready;
  final void Function(bool approve) onDecision;

  @override
  Widget build(BuildContext context) {
    final s = context.stringsRead;
    return AlertDialog(
      backgroundColor: const Color(0xFF1E293B),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(
        children: [
          const Icon(Icons.login, color: Color(0xFF38BDF8), size: 22),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              s.browserSsoTitle(spName),
              style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            s.browserSsoConfirmAs(
              identityDisplay.isEmpty ? s.browserSsoUnknownIdentity : identityDisplay,
            ),
            style: const TextStyle(color: Color(0xFFE2E8F0), fontSize: 14),
          ),
          const SizedBox(height: 12),
          if (!ready) ...[
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFF334155).withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  const Icon(Icons.timer_outlined, color: Color(0xFFFBBF24), size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      s.browserSsoNeedFreshLogon,
                      style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => onDecision(false),
          child: Text(s.browserSsoCancel, style: const TextStyle(color: Color(0xFF94A3B8))),
        ),
        ElevatedButton.icon(
          // Без живого билета/машины «Войти» недоступен — deny остаётся.
          onPressed: ready ? () => onDecision(true) : null,
          icon: const Icon(Icons.verified_user_outlined, size: 16),
          label: Text(s.browserSsoLogin),
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF0284C7),
            foregroundColor: Colors.white,
          ),
        ),
      ],
    );
  }
}
