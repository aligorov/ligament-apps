import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/debug_log_service.dart';

class DebugActionScope extends StatefulWidget {
  const DebugActionScope({super.key, required this.child, this.debugLogs});

  final Widget child;
  final DebugLogService? debugLogs;

  @override
  State<DebugActionScope> createState() => _DebugActionScopeState();
}

class _DebugActionScopeState extends State<DebugActionScope> {
  DebugLogService get _logs => widget.debugLogs ?? DebugLogService.instance;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_keyEvent);
  }

  bool _keyEvent(KeyEvent event) {
    final key = event.logicalKey;
    final phase = key == LogicalKeyboardKey.enter
        ? 'enter'
        : key == LogicalKeyboardKey.escape
            ? 'escape'
            : key == LogicalKeyboardKey.tab
                ? 'tab'
                : 'key_redacted';
    _logs.record('ui.keyboard', fields: {
      'operation': event is KeyUpEvent ? 'key_up' : 'key_down',
      'phase': phase,
      'count': 1,
    });
    return false;
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_keyEvent);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (event) => _logs.record('ui.pointer.down', fields: {
          'code': event.buttons,
          'operation': 'pointer_down',
        }),
        onPointerUp: (event) => _logs.record('ui.pointer.up', fields: {
          'operation': 'pointer_up',
        }),
        onPointerSignal: (event) => _logs.record('ui.pointer.signal', fields: {
          'operation':
              event is PointerScrollEvent ? 'scroll' : 'pointer_signal',
        }),
        child: widget.child,
      );
}

class DebugNavigationObserver extends NavigatorObserver {
  DebugNavigationObserver({DebugLogService? debugLogs})
      : _logs = debugLogs ?? DebugLogService.instance;

  final DebugLogService _logs;
  final _routes = <Route<dynamic>, int>{};

  void _record(String operation, Route<dynamic> route) {
    final id = _routes.putIfAbsent(route, _logs.nextRequestId);
    _logs.record('ui.navigation', fields: {
      'request_id': id,
      'operation': operation,
      'phase': route.runtimeType
          .toString()
          .replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_'),
      'count': _routes.length,
    });
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _record('push', route);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _record('pop', route);
    _routes.remove(route);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _record('remove', route);
    _routes.remove(route);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (oldRoute != null) _routes.remove(oldRoute);
    if (newRoute != null) _record('replace', newRoute);
  }
}
