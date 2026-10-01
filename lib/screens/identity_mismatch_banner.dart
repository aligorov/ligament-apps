import 'package:flutter/material.dart';

import '../i18n/app_strings.dart';

/// Баннер расхождения «аккаунт приложения ↔ пользователь Windows-сессии»
/// (фаза 1 Windows-identity). Чистая презентация: видимость определяет
/// home_screen по AuthState.showIdentityMismatchBanner, закрытие — на сессию.
class IdentityMismatchBanner extends StatelessWidget {
  const IdentityMismatchBanner({
    super.key,
    required this.accountUsername,
    required this.windowsUser,
    required this.onClose,
  });

  final String accountUsername;
  final String windowsUser;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final s = context.stringsRead;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      decoration: BoxDecoration(
        color: const Color(0xFF7C2D12).withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFF97316).withValues(alpha: 0.6)),
      ),
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded, color: Color(0xFFFB923C), size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              s.identityMismatchBanner(accountUsername, windowsUser),
              style: const TextStyle(color: Color(0xFFE2E8F0), fontSize: 12, height: 1.35),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, color: Color(0xFF94A3B8), size: 16),
            tooltip: s.close,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}
