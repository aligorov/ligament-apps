import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

/// Результат подтверждения доступа: проверенный 6-значный TOTP код или attemptId passkey
class RdpMfaResult {
  final bool passkey;
  final String? code;
  final String? attemptId;
  const RdpMfaResult({this.passkey = false, this.code, this.attemptId});
}

/// Диалог инлайн-подтверждения RDP-действия (MFA):
/// сервер ответил 428 mfa_required — запрашиваем Passkey или 6-значный TOTP код.
class RdpMfaDialog extends StatefulWidget {
  final bool isRu;
  final bool wrongCode;
  final dynamic localAuth;

  const RdpMfaDialog({
    super.key,
    required this.isRu,
    this.wrongCode = false,
    this.localAuth,
  });

  @override
  State<RdpMfaDialog> createState() => _RdpMfaDialogState();
}

class _RdpMfaDialogState extends State<RdpMfaDialog> {
  final _controller = TextEditingController();
  bool _isAuthenticating = false;
  String? _passkeyError;
  bool _supportsPasskey = true;

  @override
  void initState() {
    super.initState();
    _checkPasskeySupport();
  }

  Future<void> _checkPasskeySupport() async {
    try {
      final auth = widget.localAuth ?? LocalAuthentication();
      final supported = await auth.isDeviceSupported();
      if (mounted) {
        setState(() {
          _supportsPasskey = supported;
        });
      }
    } catch (_) {
      // Игнорируем ошибки проверки платформы в headless/тестовом окружении
    }
  }

  Future<void> _handlePasskey() async {
    setState(() {
      _isAuthenticating = true;
      _passkeyError = null;
    });
    try {
      final auth = widget.localAuth ?? LocalAuthentication();
      final didAuth = await auth.authenticate(
        localizedReason: widget.isRu
            ? 'Подтвердите подключение к рабочему месту (Touch ID / Windows Hello / Passkey)'
            : 'Confirm workstation connection (Touch ID / Windows Hello / Passkey)',
        options: const AuthenticationOptions(biometricOnly: false, stickyAuth: true),
      );
      if (didAuth && mounted) {
        Navigator.of(context).pop(const RdpMfaResult(passkey: true));
        return;
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _passkeyError = widget.isRu
              ? 'Ошибка подтверждения: $e'
              : 'Authentication error: $e';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isAuthenticating = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1E293B),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(
        children: [
          const Icon(Icons.security, color: Color(0xFF38BDF8), size: 22),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              widget.isRu ? 'Подтверждение доступа (2FA)' : 'Access confirmation (2FA)',
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
              widget.wrongCode
                  ? (widget.isRu
                      ? 'Код не принят — введите 6-значный TOTP код заново или подтвердите через Passkey.'
                      : 'The code was rejected — check and try again or use Passkey.')
                  : (widget.isRu
                      ? 'Рабочему месту требуется подтверждение личности. Подтвердите через Passkey или введите 6-значный код.'
                      : 'The workstation requires identity confirmation. Confirm with Passkey or enter your 6-digit code.'),
              style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
            ),
            const SizedBox(height: 16),
            if (_supportsPasskey) ...[
              OutlinedButton.icon(
                onPressed: _isAuthenticating ? null : _handlePasskey,
                icon: const Icon(Icons.fingerprint, color: Color(0xFF38BDF8), size: 20),
                label: Text(
                  widget.isRu ? '🔑 Подтвердить через Passkey' : '🔑 Confirm with Passkey',
                  style: const TextStyle(
                    color: Color(0xFF38BDF8),
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Color(0xFF0284C7)),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
              if (_passkeyError != null) ...[
                const SizedBox(height: 8),
                Text(
                  _passkeyError!,
                  style: const TextStyle(color: Color(0xFFEF4444), fontSize: 12),
                ),
              ],
              const SizedBox(height: 16),
              Row(
                children: [
                  const Expanded(child: Divider(color: Color(0xFF334155))),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text(
                      widget.isRu ? 'или TOTP код' : 'or TOTP code',
                      style: const TextStyle(color: Color(0xFF64748B), fontSize: 12),
                    ),
                  ),
                  const Expanded(child: Divider(color: Color(0xFF334155))),
                ],
              ),
              const SizedBox(height: 16),
            ],
            TextField(
              controller: _controller,
              autofocus: !_supportsPasskey,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              maxLength: 8,
              decoration: InputDecoration(
                counterText: '',
                hintText: widget.isRu ? '6-значный TOTP код' : '6-digit TOTP code',
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
                  Navigator.of(context).pop(RdpMfaResult(code: code));
                }
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(widget.isRu ? 'Отмена' : 'Cancel'),
        ),
        ElevatedButton(
          onPressed: _isAuthenticating
              ? null
              : () {
                  final code = _controller.text.trim();
                  if (code.isNotEmpty) {
                    Navigator.of(context).pop(RdpMfaResult(code: code));
                  }
                },
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF0284C7),
            foregroundColor: Colors.white,
          ),
          child: Text(widget.isRu ? 'Подтвердить кодом' : 'Confirm with code'),
        ),
      ],
    );
  }
}

/// Диалог инлайн-подтверждения RDP-действия (MFA):
/// сервер ответил 428 mfa_required — запрашиваем Passkey или 6-значный TOTP код.
Future<RdpMfaResult?> showRdpMfaDialog(
  BuildContext context, {
  required bool isRu,
  bool wrongCode = false,
  dynamic localAuth,
}) {
  return showDialog<RdpMfaResult>(
    context: context,
    barrierDismissible: false,
    builder: (_) => RdpMfaDialog(
      isRu: isRu,
      wrongCode: wrongCode,
      localAuth: localAuth,
    ),
  );
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
