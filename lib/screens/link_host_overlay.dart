import 'dart:async';

import 'package:flutter/material.dart';
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
  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    unawaited(windowManager.setPreventClose(true));
  }

  @override
  void dispose() {
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
                final status = switch (state.phase) {
                  LinkHostWorkerPhase.starting =>
                    'Подготовка защищённого канала',
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
