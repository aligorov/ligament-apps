import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Диалог инлайн-подтверждения RDP-действия кодом второго фактора
/// (фикс 10-08-3 «требование разлогиниться»): сервер ответил
/// 428 mfa_required — вместо призыва выйти и войти заново просим код
/// (TOTP / код доставки) и повторяем grant с ним.
///
/// Возвращает введённый код или null (отмена).
Future<String?> showRdpMfaCodeDialog(
  BuildContext context, {
  required bool isRu,
  bool wrongCode = false,
}) async {
  final controller = TextEditingController();
  final result = await showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (dialogCtx) => AlertDialog(
      backgroundColor: const Color(0xFF1E293B),
      title: Text(
        isRu ? 'Подтверждение доступа' : 'Access confirmation',
        style: const TextStyle(color: Colors.white, fontSize: 16),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            wrongCode
                ? (isRu
                    ? 'Код не принят — введите код заново.'
                    : 'The code was rejected — try again.')
                : (isRu
                    ? 'Рабочему месту требуется свежее подтверждение. Введите код второго фактора (приложение-аутентификатор или код доставки).'
                    : 'The workstation requires a recent confirmation. Enter a second-factor code (authenticator app or delivery code).'),
            style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: controller,
            autofocus: true,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            maxLength: 8,
            decoration: InputDecoration(
              counterText: '',
              hintText: isRu ? 'Код' : 'Code',
            ),
            style: const TextStyle(color: Colors.white, letterSpacing: 4),
            onSubmitted: (v) => Navigator.of(dialogCtx).pop(v.trim()),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogCtx).pop(),
          child: Text(isRu ? 'Отмена' : 'Cancel'),
        ),
        ElevatedButton(
          onPressed: () => Navigator.of(dialogCtx).pop(controller.text.trim()),
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF2563EB),
            foregroundColor: Colors.white,
          ),
          child: Text(isRu ? 'Подтвердить' : 'Confirm'),
        ),
      ],
    ),
  );
  controller.dispose();
  return (result == null || result.isEmpty) ? null : result;
}
