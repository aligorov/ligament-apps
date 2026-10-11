import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

int remoteMouseButton(int buttons, bool rightMode) {
  if (rightMode || (buttons & kSecondaryMouseButton) != 0) return 2;
  if ((buttons & kMiddleMouseButton) != 0) return 1;
  if ((buttons & kBackMouseButton) != 0) return 3;
  if ((buttons & kForwardMouseButton) != 0) return 4;
  return 0;
}

/// Pointer events and the video viewport share the same transformed coordinates.
/// The viewport key belongs inside InteractiveViewer, not to its outer listener.
class RemotePointerSurface extends StatelessWidget {
  const RemotePointerSurface({
    super.key,
    required this.videoKey,
    required this.videoSize,
    required this.enabled,
    required this.rightMode,
    this.trackpadScroll = true,
    required this.pressedButtons,
    required this.send,
    required this.focus,
    required this.rightClickComplete,
    required this.child,
  });

  final GlobalKey videoKey;
  final Size Function() videoSize;
  final bool enabled;
  final bool rightMode;
  final bool trackpadScroll;
  final Map<int, int> pressedButtons;
  final void Function(Map<String, dynamic>) send;
  final VoidCallback focus;
  final VoidCallback rightClickComplete;
  final Widget child;

  void _pointer(String action, PointerEvent event, int button) {
    if (!enabled) return;
    final box = videoKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize || box.size.isEmpty) return;
    final rawVideo = videoSize();
    final video = (rawVideo.width > 0 && rawVideo.height > 0)
        ? rawVideo
        : const Size(1920, 1080);
    final local = box.globalToLocal(event.position);
    final fitted = applyBoxFit(BoxFit.contain, video, box.size).destination;
    final frame = Alignment.center.inscribe(fitted, Offset.zero & box.size);
    final x = (local.dx - frame.left) / frame.width;
    final y = (local.dy - frame.top) / frame.height;
    final outside = x < 0 || x > 1 || y < 0 || y > 1;
    if (outside && action != 'mouse_up' && pressedButtons.isEmpty) return;
    send({
      'type': action,
      'x': x.clamp(0.0, 1.0),
      'y': y.clamp(0.0, 1.0),
      if (action != 'mouse_move') 'button': button,
    });
  }

  @override
  Widget build(BuildContext context) => Listener(
        behavior: HitTestBehavior.opaque,
        onPointerHover: (event) => _pointer('mouse_move', event, 0),
        onPointerMove: (event) => _pointer('mouse_move', event, 0),
        onPointerDown: (event) {
          if (!enabled) return;
          focus();
          // Ignore a down in letterboxing before recording a held button.
          final button = remoteMouseButton(event.buttons, rightMode);
          final box = videoKey.currentContext?.findRenderObject() as RenderBox?;
          if (box == null || !box.hasSize || box.size.isEmpty) return;
          final rawVideo = videoSize();
          final video = (rawVideo.width > 0 && rawVideo.height > 0)
              ? rawVideo
              : const Size(1920, 1080);
          final fitted =
              applyBoxFit(BoxFit.contain, video, box.size).destination;
          final frame =
              Alignment.center.inscribe(fitted, Offset.zero & box.size);
          if (!frame.contains(box.globalToLocal(event.position))) return;
          pressedButtons[event.pointer] = button;
          _pointer('mouse_down', event, button);
        },
        onPointerUp: (event) {
          final button = pressedButtons.remove(event.pointer);
          if (button == null) return;
          _pointer('mouse_up', event, button);
          if (rightMode) rightClickComplete();
        },
        onPointerCancel: (event) {
          final button = pressedButtons.remove(event.pointer);
          if (button != null) _pointer('mouse_up', event, button);
        },
        onPointerPanZoomUpdate: (event) {
          if (enabled && trackpadScroll && event.panDelta.dy != 0) {
            send({'type': 'wheel', 'deltaY': -event.panDelta.dy});
          }
        },
        onPointerSignal: (event) {
          if (enabled && event is PointerScrollEvent) {
            send({'type': 'wheel', 'deltaY': event.scrollDelta.dy});
          }
        },
        child: child,
      );
}
