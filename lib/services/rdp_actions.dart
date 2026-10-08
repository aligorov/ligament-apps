import 'dart:async';
import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';

import '../api/client.dart';
import '../i18n/app_strings.dart';
import '../screens/rdp_connect_dialog.dart';
import '../screens/support_operator_screen.dart';
import '../services/auth_state.dart';
import '../services/rdp_service.dart';
import '../widgets/rdp_mfa_dialog.dart';

/// Сервис общих действий с рабочими местами RDP и «Экран»:
/// переиспользуется между HomeScreen и AppsScreen.
class RdpActions {
  static bool _ownerScreenBusy = false;
  static bool get isOwnerScreenBusy => _ownerScreenBusy;

  /// Запуск RDP-туннеля по целевому рабочему месту.
  static Future<void> connectRdp(
    BuildContext context,
    AuthState auth,
    Map<String, dynamic> target,
  ) async {
    final api = auth.api;
    final baseUrl = auth.serverUrl;
    final id = target['id']?.toString() ?? '';
    if (api == null || baseUrl == null || id.isEmpty) return;
    if (auth.rdp.isBusy || auth.rdp.isActive) return;
    final name = target['name']?.toString() ?? '';

    unawaited(
      auth.rdp.connect(
        api: api,
        baseUrl: baseUrl,
        targetId: id,
        name: name,
        isRu: auth.isRu,
        mfaPrompt: (wrong) =>
            showRdpMfaDialog(context, isRu: auth.isRu, wrongCode: wrong, localAuth: auth.localAuth),
      ),
    );
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => RdpConnectDialog(connector: auth.rdp, targetName: name),
    );
  }

  /// Открытие экрана своего ПК (owner mode).
  static Future<void> openOwnerScreen(
    BuildContext context,
    AuthState auth,
    Map<String, dynamic> target, {
    void Function(bool busy)? onBusyChanged,
  }) async {
    final api = auth.api;
    final targetId = target['id']?.toString() ?? '';
    final targetName = target['name']?.toString() ?? '';
    if (api == null || targetId.isEmpty || _ownerScreenBusy) return;

    _ownerScreenBusy = true;
    onBusyChanged?.call(true);
    final s = context.stringsRead;
    unawaited(_showOwnerScreenProgress(context, s.ownerScreenProgress(targetName)));
    try {
      String? beforeId;
      try {
        beforeId = (await api.getCurrentSupportSession())?['id']?.toString();
      } catch (_) {}

      Map<String, dynamic>? grant;
      {
        String? code;
        bool passkey = false;
        bool autoPasskeyAttempted = false;
        while (true) {
          try {
            grant = await api.rdpGrant(
              targetId: targetId,
              mode: 'screen',
              code: code,
              passkey: passkey,
            );
            break;
          } on ApiException catch (e) {
            if (e.statusCode != 428 && e.code != 'invalid_code') rethrow;
            if (!context.mounted) return;
            _popOwnerScreenProgress(context);

            // 1. Автоматический вызов Passkey (Touch ID / Windows Hello) при первом запросе
            if (e.statusCode == 428 && !autoPasskeyAttempted) {
              autoPasskeyAttempted = true;
              try {
                if (await auth.localAuth.isDeviceSupported()) {
                  final didAuth = await auth.localAuth.authenticate(
                    localizedReason: s.isRu
                        ? 'Подтвердите доступ к экрану рабочего стола (Touch ID / Windows Hello)'
                        : 'Confirm desktop screen access (Touch ID / Windows Hello)',
                    options: const AuthenticationOptions(biometricOnly: false, stickyAuth: true),
                  );
                  if (didAuth) {
                    passkey = true;
                    code = null;
                    if (context.mounted) {
                      unawaited(_showOwnerScreenProgress(context, s.ownerScreenProgress(targetName)));
                    }
                    continue;
                  }
                }
              } catch (_) {}
            }

            if (!context.mounted) break;
            // 2. Если Passkey не сработал или отменён — диалог с выбором (Passkey или TOTP)
            final res = await showRdpMfaDialog(
              context,
              isRu: s.isRu,
              wrongCode: e.code == 'invalid_code',
              localAuth: auth.localAuth,
            );
            if (res == null) break;
            if (res.passkey) {
              passkey = true;
              code = null;
            } else {
              passkey = false;
              code = res.code;
            }
            if (!context.mounted) return;
            unawaited(_showOwnerScreenProgress(context, s.ownerScreenProgress(targetName)));
          }
        }
      }
      if (grant == null) {
        if (context.mounted) _popOwnerScreenProgress(context);
        return;
      }

      String grantSessionId = grant['session_id']?.toString() ??
          grant['support_session_id']?.toString() ??
          '';
      final sessObj = grant['session'];
      if (grantSessionId.isEmpty && sessObj is Map) {
        grantSessionId = sessObj['id']?.toString() ?? '';
      }
      Map<String, dynamic>? session;
      if (grantSessionId.isNotEmpty) {
        session = <String, dynamic>{
          if (sessObj is Map) ...Map<String, dynamic>.from(sessObj),
          'id': grantSessionId,
        };
      } else {
        session = await _waitOwnerScreenSession(api, beforeId);
      }

      if (!context.mounted) return;
      _popOwnerScreenProgress(context);

      if (session == null) {
        final grantId = grant['grant_id']?.toString() ?? '';
        if (grantId.isNotEmpty) {
          unawaited(api.rdpClose(grantId).catchError((_) {}));
        }
        await _showOwnerScreenError(
          context,
          s,
          s.ownerScreenUnsupportedTitle,
          s.ownerScreenUnsupportedBody,
        );
        return;
      }

      final sessionId = session['id']?.toString() ?? grantSessionId;
      if (sessionId.isEmpty) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          fullscreenDialog: true,
          builder: (_) => SupportOperatorScreen(
            sessionId: sessionId,
            sessionData: <String, dynamic>{
              ...target,
              ...session!,
              'access_mode': 'full_control',
              'owner': true,
            },
            ownerMode: true,
          ),
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      _popOwnerScreenProgress(context);
      await _showOwnerScreenError(
        context,
        s,
        s.error,
        rdpConnectErrorText(e, isRu: s.isRu),
      );
    } finally {
      _ownerScreenBusy = false;
      onBusyChanged?.call(false);
    }
  }

  static Future<Map<String, dynamic>?> _waitOwnerScreenSession(
    ApiClient api,
    String? beforeId, {
    Duration timeout = const Duration(seconds: 12),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      try {
        final sess = await api.getCurrentSupportSession();
        if (sess != null) {
          final id = sess['id']?.toString() ?? '';
          final isOwner = sess['owner'] == true || sess['mode']?.toString() == 'screen';
          final isNew = beforeId == null || beforeId.isEmpty || id != beforeId;
          if (id.isNotEmpty && (isOwner || isNew)) {
            return sess;
          }
        }
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 1200));
    }
    return null;
  }

  static void _popOwnerScreenProgress(BuildContext context) {
    final nav = Navigator.of(context, rootNavigator: true);
    if (nav.canPop()) {
      nav.pop();
    }
  }

  static Future<void> _showOwnerScreenProgress(BuildContext context, String text) async {
    if (!context.mounted) return;
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: AlertDialog(
          backgroundColor: const Color(0xFF0F172A),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: Color(0xFF334155)),
          ),
          content: Row(
            children: [
              const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: Color(0xFF38BDF8),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  text,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static Future<void> _showOwnerScreenError(
    BuildContext context,
    AppStrings s,
    String title,
    String body,
  ) async {
    if (!context.mounted) return;
    await showDialog(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            const Icon(Icons.error_outline, color: Color(0xFFEF4444), size: 22),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(color: Colors.white, fontSize: 16),
              ),
            ),
          ],
        ),
        content: Text(
          body,
          style: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 13),
        ),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.of(dialogCtx).pop(),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF334155),
              foregroundColor: Colors.white,
            ),
            child: Text(s.close),
          ),
        ],
      ),
    );
  }
}
