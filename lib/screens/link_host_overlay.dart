import 'dart:async';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../i18n/app_strings.dart';
import '../services/link_host_session.dart';
import 'support_approval_modal.dart';

/// Link uses the actual SOS approval component, not a separate consent form.
class LinkHostOverlay extends StatefulWidget {
  const LinkHostOverlay({required this.state, super.key});
  final LinkHostWorkerState state;
  @override
  State<LinkHostOverlay> createState() => _LinkHostOverlayState();
}

class _LinkHostOverlayState extends State<LinkHostOverlay> with WindowListener {
  bool? _expanded;
  Future<void> _windowUpdates = Future<void>.value();

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    widget.state.addListener(_syncWindow);
    unawaited(windowManager.setPreventClose(true));
    _syncWindow();
  }

  void _syncWindow() {
    final expanded = widget.state.phase == LinkHostWorkerPhase.awaitingConsent;
    if (_expanded == expanded) return;
    _expanded = expanded;
    _windowUpdates = _windowUpdates.then((_) async {
      if (!mounted) return;
      await windowManager.setMinimumSize(const Size(460, 120));
      await windowManager
          .setSize(expanded ? const Size(560, 760) : const Size(800, 160));
      await windowManager.center();
      if (expanded) {
        await windowManager.show();
        await windowManager.focus();
      }
    }).catchError((Object error) {
      debugPrint('link_host: window layout unavailable: ${error.runtimeType}');
    });
  }

  @override
  void dispose() {
    widget.state.removeListener(_syncWindow);
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowClose() => widget.state.requestDisconnect();

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          backgroundColor: const Color(0xFF10251D),
          body: SafeArea(
              child: AnimatedBuilder(
            animation: widget.state,
            builder: (context, _) {
              final state = widget.state;
              if (state.phase == LinkHostWorkerPhase.awaitingConsent) {
                return Center(
                    child: SingleChildScrollView(
                        child: SupportApprovalModal(
                  key: ValueKey(state.sessionId),
                  stringsOverride: AppStrings('ru'),
                  prompt: <String, dynamic>{
                    'session_id': state.sessionId,
                    'admin_name': state.operatorName,
                    'access_mode': state.accessMode == 'control'
                        ? 'full_control'
                        : 'view_only',
                    'problem_summary': 'Ligament Link',
                    'category': 'it',
                  },
                  // Only length reaches the host; the server verifies the digits.
                  numberMatchLength: state.confirmationDigits,
                  onApprove: (code) async => state.approveConsent(code),
                  onDeny: () async => state.denyConsent(),
                )));
              }
              final closing = state.phase == LinkHostWorkerPhase.closing ||
                  state.phase == LinkHostWorkerPhase.closed;
              final status = switch (state.phase) {
                LinkHostWorkerPhase.starting => 'Подготовка защищённого канала',
                LinkHostWorkerPhase.awaitingConsent => 'Ожидание подтверждения',
                LinkHostWorkerPhase.connecting =>
                  'Удалённое подключение устанавливается',
                LinkHostWorkerPhase.active => 'Удалённая сессия активна',
                LinkHostWorkerPhase.closing => 'Отключение…',
                LinkHostWorkerPhase.closed => 'Сессия завершена',
              };
              return Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Row(children: [
                  const Icon(Icons.screen_share, color: Color(0xFF4ADE80)),
                  const SizedBox(width: 12),
                  Expanded(
                      child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(status,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700)),
                      const SizedBox(height: 4),
                      Text(
                          '${state.operatorName} · ${state.accessMode == 'control' ? 'Управление' : 'Просмотр'}',
                          style: const TextStyle(
                              color: Color(0xFFB7C8BE), fontSize: 12)),
                    ],
                  )),
                  const SizedBox(width: 12),
                  FilledButton(
                      onPressed: closing ? null : state.requestDisconnect,
                      style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFFB42318)),
                      child: const Text('Отключить')),
                ]),
              );
            },
          )),
        ),
      );
}
