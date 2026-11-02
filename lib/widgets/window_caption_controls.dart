import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

/// Стандартные кнопки управления окном (Свернуть, Развернуть / Восстановить, Закрыть).
/// Поддерживают нативный hover-эффект, корректное состояние Maximize и
/// делегируют закрытие окну с учетом системного трея и подтверждения SOS.
class WindowCaptionControls extends StatefulWidget {
  final Color? iconColor;
  final double height;

  const WindowCaptionControls({
    super.key,
    this.iconColor,
    this.height = 34,
  });

  /// Доступны ли функции управления окном на текущей платформе
  static bool get isSupported =>
      !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  @override
  State<WindowCaptionControls> createState() => _WindowCaptionControlsState();
}

class _WindowCaptionControlsState extends State<WindowCaptionControls>
    with WindowListener {
  bool _isMaximized = false;

  @override
  void initState() {
    super.initState();
    if (WindowCaptionControls.isSupported) {
      windowManager.addListener(this);
      _checkMaximized();
    }
  }

  @override
  void dispose() {
    if (WindowCaptionControls.isSupported) {
      windowManager.removeListener(this);
    }
    super.dispose();
  }

  Future<void> _checkMaximized() async {
    try {
      final max = await windowManager.isMaximized();
      if (mounted) setState(() => _isMaximized = max);
    } catch (_) {}
  }

  @override
  void onWindowMaximize() {
    if (mounted) setState(() => _isMaximized = true);
  }

  @override
  void onWindowUnmaximize() {
    if (mounted) setState(() => _isMaximized = false);
  }

  @override
  Widget build(BuildContext context) {
    if (!WindowCaptionControls.isSupported) {
      return const SizedBox.shrink();
    }

    final color = widget.iconColor ?? Colors.white.withValues(alpha: 0.85);

    return SizedBox(
      height: widget.height,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // 1. Свернуть
          _CaptionButton(
            icon: Icons.horizontal_rule_rounded,
            tooltip: 'Свернуть',
            iconColor: color,
            hoverColor: Colors.white.withValues(alpha: 0.12),
            onPressed: () => windowManager.minimize(),
          ),
          // 2. Развернуть / Восстановить
          _CaptionButton(
            icon: _isMaximized ? Icons.filter_none_rounded : Icons.crop_square_rounded,
            tooltip: _isMaximized ? 'Восстановить' : 'Развернуть',
            iconColor: color,
            iconSize: _isMaximized ? 13 : 15,
            hoverColor: Colors.white.withValues(alpha: 0.12),
            onPressed: () async {
              try {
                if (await windowManager.isMaximized()) {
                  await windowManager.unmaximize();
                } else {
                  await windowManager.maximize();
                }
              } catch (_) {}
            },
          ),
          // 3. Закрыть (сворачивает в трей или завершает согласно GPO)
          _CaptionButton(
            icon: Icons.close_rounded,
            tooltip: 'Закрыть',
            iconColor: color,
            hoverColor: const Color(0xFFEF4444),
            onPressed: () => windowManager.close(),
          ),
        ],
      ),
    );
  }
}

class _CaptionButton extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final Color iconColor;
  final Color hoverColor;
  final double iconSize;
  final VoidCallback onPressed;

  const _CaptionButton({
    required this.icon,
    required this.tooltip,
    required this.iconColor,
    required this.hoverColor,
    required this.onPressed,
    this.iconSize = 16,
  });

  @override
  State<_CaptionButton> createState() => _CaptionButtonState();
}

class _CaptionButtonState extends State<_CaptionButton> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 600),
      child: MouseRegion(
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPressed,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            curve: Curves.easeOut,
            width: 36,
            height: 30,
            decoration: BoxDecoration(
              color: _isHovered ? widget.hoverColor : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Center(
              child: Icon(
                widget.icon,
                size: widget.iconSize,
                color: _isHovered ? Colors.white : widget.iconColor,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
