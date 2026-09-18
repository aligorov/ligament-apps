import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../services/auth_state.dart';
import '../i18n/app_strings.dart';

/// Модальное окно Zero-Trust подтверждения удаленного доступа с Number Matching.
///
/// Подтверждение строго осознанное: код, продиктованный инженером по телефону,
/// вводится с клавиатуры (выбор из кнопок исключал случайный/подсказанный
/// клик). Пока код не введён, кнопка «Разрешить» неактивна. Режим доступа
/// (полный контроль / только просмотр) показывается ДО подтверждения.
class SupportApprovalModal extends StatefulWidget {
  final Map<String, dynamic> prompt;

  const SupportApprovalModal({super.key, required this.prompt});

  @override
  State<SupportApprovalModal> createState() => _SupportApprovalModalState();
}

class _SupportApprovalModalState extends State<SupportApprovalModal> {
  final TextEditingController _codeController = TextEditingController();
  final FocusNode _codeFocus = FocusNode();
  bool _processing = false;
  String? _error;
  Timer? _expiryTimer;

  @override
  void initState() {
    super.initState();
    _codeController.addListener(() {
      if (_error != null) setState(() => _error = null);
    });
    _armExpiryWatch();
  }

  /// m-3: авто-закрытие по истечении срока промпта (если сервер передал
  /// expires_at/expires_in_seconds).
  void _armExpiryWatch() {
    DateTime? expiresAt;
    final raw = widget.prompt['expires_at'];
    if (raw is int) {
      expiresAt = DateTime.fromMillisecondsSinceEpoch(raw * 1000);
    } else if (raw is num) {
      expiresAt = DateTime.fromMillisecondsSinceEpoch((raw * 1000).round());
    } else if (raw is String) {
      expiresAt = DateTime.tryParse(raw);
    }
    final inSeconds = (widget.prompt['expires_in_seconds'] as num?)?.toInt();
    if (expiresAt == null && inSeconds != null && inSeconds > 0) {
      expiresAt = DateTime.now().add(Duration(seconds: inSeconds));
    }
    if (expiresAt == null) return;
    final wait = expiresAt.difference(DateTime.now());
    if (wait.isNegative) {
      _close();
      return;
    }
    _expiryTimer = Timer(wait, _close);
  }

  void _close() {
    if (mounted && Navigator.of(context).canPop()) {
      Navigator.of(context).pop(false);
    }
  }

  @override
  void dispose() {
    _expiryTimer?.cancel();
    _codeController.dispose();
    _codeFocus.dispose();
    super.dispose();
  }

  /// Контрольное число обязано присутствовать: без него подтверждение
  /// невозможно в принципе (сервер такой approve тоже отклонит).
  String get _expectedMatch => widget.prompt['number_match']?.toString() ?? '';

  bool get _codeEntered => _codeController.text.trim().length == _expectedMatch.length;

  Future<void> _approve() async {
    final strings = context.stringsRead;
    if (!_codeEntered) {
      setState(() => _error = strings.errEnterMatch);
      return;
    }
    if (_codeController.text.trim() != _expectedMatch) {
      setState(() => _error = strings.errWrongMatchPhone);
      return;
    }

    setState(() {
      _processing = true;
      _error = null;
    });

    try {
      final auth = context.read<AuthState>();
      final sessId = widget.prompt['session_id']?.toString() ?? '';
      await auth.confirmSupport(
        sessionId: sessId,
        numberMatch: _codeController.text.trim(),
      );

      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _processing = false;
          _error = '${context.stringsRead.errApprovalPrefix}: $e';
        });
      }
    }
  }

  Future<void> _deny() async {
    setState(() => _processing = true);
    try {
      final auth = context.read<AuthState>();
      final sessId = widget.prompt['session_id']?.toString() ?? '';
      await auth.rejectSupport(sessionId: sessId);
    } catch (_) {}
    if (mounted) {
      Navigator.of(context).pop(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = context.strings;
    final auth = context.watch<AuthState>();

    // m-3: промпт исчез (сессия завершена/отклонена на сервере или из другого
    // канала) — модалка закрывается сама, «висящее» окно подтверждения
    // не должно пережить свой запрос. Во время обработки решения не закрываем.
    if (!_processing) {
      final current = auth.activeSupportPrompt;
      final gone = current == null ||
          (current['session_id']?.toString() ?? '') != (widget.prompt['session_id']?.toString() ?? '');
      if (gone) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && Navigator.of(context).canPop()) {
            Navigator.of(context).pop(false);
          }
        });
      }
    }

    final category = widget.prompt['category']?.toString() ?? 'it';
    final summary = widget.prompt['problem_summary']?.toString() ?? (strings.isRu ? 'Удаленная помощь' : 'Remote support');
    final operatorName = widget.prompt['admin_name']?.toString() ??
        widget.prompt['operator']?.toString() ??
        strings.defaultEngineer;
    final accessMode = widget.prompt['access_mode']?.toString() ?? 'full_control';
    final fullControl = accessMode != 'view_only';

    return Dialog(
      backgroundColor: const Color(0xFF1E293B),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Container(
        padding: const EdgeInsets.all(24),
        constraints: const BoxConstraints(maxWidth: 440),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Иконка замка и безопасность
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: fullControl
                    ? const Color(0xFFF59E0B).withValues(alpha: 0.12)
                    : const Color(0xFF38BDF8).withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(
                fullControl ? Icons.lock : Icons.visibility,
                size: 48,
                color: fullControl ? const Color(0xFFF59E0B) : const Color(0xFF38BDF8),
              ),
            ),
            const SizedBox(height: 16),

            Text(
              fullControl ? strings.supportApprovalTitleFull : strings.supportApprovalTitleView,
              style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Text(
              category == '1c' ? strings.oneCReady : strings.itOnDuty,
              style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),

            // Карточка деталей
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFF0F172A),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xFF334155)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.person_outline, size: 16, color: Color(0xFF94A3B8)),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          operatorName,
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: category == '1c'
                              ? const Color(0xFFF59E0B).withValues(alpha: 0.2)
                              : const Color(0xFF0284C7).withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          category == '1c' ? strings.oneCSupportBadge : strings.itSupportBadge,
                          style: TextStyle(
                            color: category == '1c' ? const Color(0xFFF59E0B) : const Color(0xFF38BDF8),
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const Divider(color: Color(0xFF334155), height: 16),
                  Text(
                    '${strings.problemSummaryPrefix} "$summary"',
                    style: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 12),
                  ),
                  const SizedBox(height: 8),
                  // Режим доступа — строго ДО подтверждения.
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: fullControl
                          ? const Color(0xFFEF4444).withValues(alpha: 0.12)
                          : const Color(0xFF10B981).withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          fullControl ? Icons.warning_amber_rounded : Icons.visibility_outlined,
                          size: 16,
                          color: fullControl ? const Color(0xFFF87171) : const Color(0xFF34D399),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            fullControl ? strings.fullControlDesc : strings.viewOnlyDesc,
                            style: TextStyle(
                              color: fullControl ? const Color(0xFFF87171) : const Color(0xFF34D399),
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            // Number Matching: ввод кода с клавиатуры
            if (_expectedMatch.isNotEmpty) ...[
              Text(
                strings.numberMatchTitle,
                style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              Text(
                strings.numberMatchVoiceDesc,
                style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: 160,
                child: TextField(
                  controller: _codeController,
                  focusNode: _codeFocus,
                  enabled: !_processing,
                  keyboardType: TextInputType.number,
                  textAlign: TextAlign.center,
                  maxLength: _expectedMatch.length,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 30,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 12,
                  ),
                  decoration: InputDecoration(
                    counterText: '',
                    hintText: '••',
                    hintStyle: const TextStyle(color: Color(0xFF475569), fontSize: 30, letterSpacing: 12),
                    filled: true,
                    fillColor: const Color(0xFF0F172A),
                    contentPadding: const EdgeInsets.symmetric(vertical: 12),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: const BorderSide(color: Color(0xFF334155), width: 2),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: const BorderSide(color: Color(0xFF38BDF8), width: 2),
                    ),
                  ),
                  onSubmitted: (_) => _codeEntered ? _approve() : null,
                ),
              ),
            ] else ...[
              // Кода нет — подтвердить нельзя (сервер тоже откажет).
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFEF4444).withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFF7F1D1D)),
                ),
                child: Text(
                  strings.noCodeNotice,
                  style: const TextStyle(color: Color(0xFFFCA5A5), fontSize: 12),
                  textAlign: TextAlign.center,
                ),
              ),
            ],

            if (_error != null) ...[
              const SizedBox(height: 14),
              Text(
                _error!,
                style: const TextStyle(color: Color(0xFFEF4444), fontSize: 12, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
            ],

            const SizedBox(height: 24),

            // Кнопки: «Разрешить» активна ТОЛЬКО при введённом коде
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _processing ? null : _deny,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFFEF4444),
                      side: const BorderSide(color: Color(0xFFEF4444)),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: Text(strings.denyBtn),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: ElevatedButton(
                    onPressed: (_processing || !_codeEntered || _expectedMatch.isEmpty) ? null : _approve,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF10B981),
                      foregroundColor: Colors.white,
                      disabledBackgroundColor: const Color(0xFF064E3B),
                      disabledForegroundColor: const Color(0xFF64748B),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: _processing
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                          )
                        : Text(
                            strings.allowAccessBtn,
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                          ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
