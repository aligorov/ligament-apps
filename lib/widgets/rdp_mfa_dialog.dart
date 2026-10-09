import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Результат подтверждения доступа: проверенный 6-значный TOTP код или attemptId passkey
class RdpMfaResult {
  final bool passkey;
  final String? code;
  final String? attemptId;
  const RdpMfaResult({this.passkey = false, this.code, this.attemptId});
}

/// Диалог инлайн-подтверждения RDP-действия (MFA):
/// сервер ответил 428 mfa_required — запрашиваем 6-значный TOTP код.
Future<RdpMfaResult?> showRdpMfaDialog(
  BuildContext context, {
  required bool isRu,
  bool wrongCode = false,
  dynamic localAuth,
}) async {
  final controller = TextEditingController();

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
              isRu ? 'Подтверждение доступа (2FA)' : 'Access confirmation (2FA)',
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
                      ? 'Код не принят — введите 6-значный TOTP код заново.'
                      : 'The code was rejected — check and try again.')
                  : (isRu
                      ? 'Рабочему месту требуется свежее подтверждение личности. Введите 6-значный код из аутентификатора.'
                      : 'The workstation requires a recent identity confirmation. Enter your 6-digit authenticator code.'),
              style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              autofocus: true,
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
            backgroundColor: const Color(0xFF0284C7),
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
