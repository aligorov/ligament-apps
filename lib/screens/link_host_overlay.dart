import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../services/link_host_session.dart';

/// Local, always-on-top notice for the host side of a Link session.
class LinkHostOverlay extends StatefulWidget {
  const LinkHostOverlay({required this.state, super.key});

  final LinkHostWorkerState state;

  @override
  State<LinkHostOverlay> createState() => _LinkHostOverlayState();
}

class _LinkHostOverlayState extends State<LinkHostOverlay> with WindowListener {
  final _code = TextEditingController();
  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    unawaited(windowManager.setPreventClose(true));
  }

  @override
  void dispose() {
    _code.dispose();
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
                final isClosing = state.phase == LinkHostWorkerPhase.closing ||
                    state.phase == LinkHostWorkerPhase.closed;
                final awaitingConsent =
                    state.phase == LinkHostWorkerPhase.awaitingConsent;
                final status = switch (state.phase) {
                  LinkHostWorkerPhase.starting =>
                    'Подготовка защищённого канала',
                  LinkHostWorkerPhase.awaitingConsent =>
                    'Разрешить удалённое подключение?',
                  LinkHostWorkerPhase.connecting =>
                    'Удалённое подключение устанавливается',
                  LinkHostWorkerPhase.active => 'Удалённая сессия активна',
                  LinkHostWorkerPhase.closing => 'Отключение…',
                  LinkHostWorkerPhase.closed => 'Сессия завершена',
                };
                final mode =
                    state.accessMode == 'control' ? 'Управление' : 'Просмотр';
                return Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  child: Row(
                    children: [
                      const Icon(Icons.screen_share, color: Color(0xFF4ADE80)),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              status,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '${state.operatorName.isEmpty ? 'Оператор подтверждён сервером' : state.operatorName} · $mode',
                              style: const TextStyle(
                                color: Color(0xFFB7C8BE),
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      if (awaitingConsent) ...[
                        SizedBox(
                          width: 165,
                          child: TextField(
                            key: const Key('link-confirmation-code'),
                            controller: _code,
                            keyboardType: TextInputType.number,
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly,
                              LengthLimitingTextInputFormatter(6)
                            ],
                            style: const TextStyle(color: Colors.white),
                            decoration: const InputDecoration(
                              labelText: 'Код оператора',
                              hintText: 'Введите 3 или 6 цифр',
                            ),
                            onChanged: (_) => setState(() {}),
                          ),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: RegExp(r'^(?:[0-9]{3}|[0-9]{6})$')
                                  .hasMatch(_code.text)
                              ? () {
                                  state.approveConsent(_code.text);
                                  _code.clear();
                                }
                              : null,
                          child: const Text('Разрешить'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: state.denyConsent,
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFFB42318),
                          ),
                          child: const Text('Отклонить'),
                        ),
                      ] else
                        FilledButton(
                          onPressed:
                              isClosing ? null : widget.state.requestDisconnect,
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFFB42318),
                          ),
                          child: const Text('Отключить'),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      );
}
