import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

/// Результат подтверждения доступа: Passkey или введённый код
class RdpMfaResult {
  final bool passkey;
  final String? code;
  const RdpMfaResult({this.passkey = false, this.code});
}

/// Диалог инлайн-подтверждения RDP-действия (MFA):
/// сервер ответил 428 mfa_required — предлагаем подтверждение через
/// системный Passkey (Touch ID / Windows Hello) или ввод 6-значного кода TOTP.
Future<RdpMfaResult?> showRdpMfaDialog(
  BuildContext context, {
  required bool isRu,
  bool wrongCode = false,
  LocalAuthentication? localAuth,
}) async {
  final controller = TextEditingController();
  final auth = localAuth ?? LocalAuthentication();

  Future<void> tryPasskey(BuildContext dialogCtx) async {
    try {
      final isSupported = await auth.isDeviceSupported();
      if (!isSupported) {
        if (dialogCtx.mounted) {
          ScaffoldMessenger.of(dialogCtx).showSnackBar(
            SnackBar(
              content: Text(
                isRu
                    ? 'Биометрия / Passkey недоступны на этом устройстве'
                    : 'Biometrics / Passkey not available on this device',
              ),
            ),
          );
        }
        return;
      }
      final didAuth = await auth.authenticate(
        localizedReason: isRu
            ? 'Подтвердите доступ к рабочему столу (Touch ID / Windows Hello)'
            : 'Confirm workstation access (Touch ID / Windows Hello)',
        options: const AuthenticationOptions(biometricOnly: false, stickyAuth: true),
      );
      if (didAuth && dialogCtx.mounted) {
        Navigator.of(dialogCtx).pop(const RdpMfaResult(passkey: true));
      }
    } catch (_) {}
  }

  final result = await showDialog<RdpMfaResult>(
    context: context,
    barrierDismissible: false,
    builder: (dialogCtx) => AlertDialog(
      backgroundColor: const Color(0xFF1E293B),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(
        children: [
          const Icon(Icons.security, color: Color(0xFF38BDF8), size: 22),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              isRu ? 'Подтверждение доступа' : 'Access confirmation',
              style: const TextStyle(color: Colors.white, fontSize: 16),
            ),
          ),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              wrongCode
                  ? (isRu
                      ? 'Код не принят — введите код заново или используйте Passkey.'
                      : 'The code was rejected — try again or use Passkey.')
                  : (isRu
                      ? 'Рабочему месту требуется свежее подтверждение личности.'
                      : 'The workstation requires a recent identity confirmation.'),
              style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: () => tryPasskey(dialogCtx),
              icon: const Icon(Icons.fingerprint, color: Colors.white, size: 20),
              label: Text(
                isRu ? '🔑 Подтвердить через Passkey' : '🔑 Confirm with Passkey',
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF0284C7),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                const Expanded(child: Divider(color: Color(0xFF334155))),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(
                    isRu ? 'или введите код' : 'or enter code',
                    style: const TextStyle(color: Color(0xFF64748B), fontSize: 11),
                  ),
                ),
                const Expanded(child: Divider(color: Color(0xFF334155))),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: wrongCode,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              maxLength: 8,
              decoration: InputDecoration(
                counterText: '',
                hintText: isRu ? '6-значный TOTP код' : '6-digit TOTP code',
                isDense: true,
                filled: true,
                fillColor: const Color(0xFF0F172A),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: Color(0xFF334155)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: Color(0xFF334155)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: Color(0xFF38BDF8)),
                ),
              ),
              style: const TextStyle(color: Colors.white, letterSpacing: 4),
              onSubmitted: (v) {
                final code = v.trim();
                if (code.isNotEmpty) {
                  Navigator.of(dialogCtx).pop(RdpMfaResult(code: code));
                }
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogCtx).pop(),
          child: Text(isRu ? 'Отмена' : 'Cancel'),
        ),
        ElevatedButton(
          onPressed: () {
            final code = controller.text.trim();
            if (code.isNotEmpty) {
              Navigator.of(dialogCtx).pop(RdpMfaResult(code: code));
            }
          },
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF334155),
            foregroundColor: Colors.white,
          ),
          child: Text(isRu ? 'Подтвердить кодом' : 'Confirm with code'),
        ),
      ],
    ),
  );
  controller.dispose();
  return result;
}

/// Обратная совместимость для вызова чисто кодом
Future<String?> showRdpMfaCodeDialog(
  BuildContext context, {
  required bool isRu,
  bool wrongCode = false,
}) async {
  final res = await showRdpMfaDialog(context, isRu: isRu, wrongCode: wrongCode);
  return res?.code;
}

