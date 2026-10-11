import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ligament_authenticator/widgets/remote_pointer_surface.dart';

void main() {
  late List<Map<String, dynamic>> commands;
  late Map<int, int> pressed;
  late GlobalKey videoKey;
  Future<void> surface(WidgetTester tester,
      {bool enabled = true, bool right = false, double zoom = 1}) async {
    commands = [];
    pressed = {};
    videoKey = GlobalKey();
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 400,
            height: 300,
            child: RemotePointerSurface(
              videoKey: videoKey,
              videoSize: () => const Size(1920, 1080),
              enabled: enabled,
              rightMode: right,
              pressedButtons: pressed,
              send: commands.add,
              focus: () {},
              rightClickComplete: () {},
              child: InteractiveViewer(
                transformationController: TransformationController(
                    Matrix4.diagonal3Values(zoom, zoom, 1)),
                child: SizedBox(key: videoKey, width: 400, height: 300),
              ),
            ),
          )),
    ));
  }

  for (final button in <int, int>{
    kPrimaryMouseButton: 0,
    kMiddleMouseButton: 1,
    kSecondaryMouseButton: 2
  }.entries) {
    testWidgets(
        'mouse button ${button.value} reaches down/up with paired identity',
        (tester) async {
      await surface(tester);
      final mouse = await tester.createGesture(
          kind: PointerDeviceKind.mouse, buttons: button.key);
      await mouse.down(const Offset(200, 150));
      await mouse.up();
      expect(commands.map((e) => e['type']), ['mouse_down', 'mouse_up']);
      for (final command in commands) {
        expect(command['button'], button.value);
        expect(command['x'], closeTo(0.5, 0.0001));
        expect(command['y'], closeTo(0.5, 0.0001));
      }
      expect(pressed, isEmpty);
    });
  }
  testWidgets(
      'hover and wheel reach transport on an otherwise empty video surface',
      (tester) async {
    await surface(tester);
    await tester.sendEventToBinding(const PointerHoverEvent(
        position: Offset(200, 150), kind: PointerDeviceKind.mouse));
    await tester.sendEventToBinding(const PointerScrollEvent(
        position: Offset(200, 150),
        scrollDelta: Offset(0, 120),
        kind: PointerDeviceKind.mouse));
    expect(commands.map((e) => e['type']), ['mouse_move', 'wheel']);
    expect(commands.last['deltaY'], 120);
  });
  testWidgets('letterboxing does not start a remote click', (tester) async {
    await surface(tester);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.down(const Offset(200, 10));
    await mouse.up();
    expect(commands, isEmpty);
    expect(pressed, isEmpty);
  });
  testWidgets(
      'drag and up outside frame are clamped and release the held button',
      (tester) async {
    await surface(tester);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.down(const Offset(200, 150));
    await mouse.moveTo(const Offset(-20, 500));
    await mouse.up();
    expect(commands.last['type'], 'mouse_up');
    expect(commands.last['x'], 0);
    expect(commands.last['y'], 1);
    expect(pressed, isEmpty);
  });
  testWidgets('zoom coordinates use the transformed video box', (tester) async {
    await surface(tester, zoom: 2);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.down(const Offset(200, 150));
    await mouse.up();
    expect(commands.first['x'], closeTo(0.25, 0.0001));
    expect(commands.first['y'], closeTo(1 / 6, 0.0001));
  });
  testWidgets('view only blocks pointer input', (tester) async {
    await surface(tester, enabled: false);
    await tester.tapAt(const Offset(200, 150));
    await tester.sendEventToBinding(const PointerHoverEvent(
        position: Offset(200, 150), kind: PointerDeviceKind.mouse));
    expect(commands, isEmpty);
  });
  testWidgets('forced right click sends button 2 for both edges',
      (tester) async {
    await surface(tester, right: true);
    await tester.tapAt(const Offset(200, 150));
    expect(commands.map((e) => e['button']), [2, 2]);
  });
  testWidgets('Mac trackpad pan delivers wheel input in fit mode',
      (tester) async {
    await surface(tester);
    await tester.sendEventToBinding(const PointerPanZoomStartEvent(
        pointer: 99, position: Offset(200, 150)));
    await tester.sendEventToBinding(const PointerPanZoomUpdateEvent(
        pointer: 99,
        position: Offset(200, 150),
        pan: Offset(0, 40),
        panDelta: Offset(0, 40)));
    await tester.sendEventToBinding(
        const PointerPanZoomEndEvent(pointer: 99, position: Offset(200, 150)));
    expect(commands, [
      {'type': 'wheel', 'deltaY': -40.0}
    ]);
  });
  testWidgets('double click preserves four distinct button edges',
      (tester) async {
    await surface(tester);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.down(const Offset(200, 150));
    await mouse.up();
    await tester.pump(const Duration(milliseconds: 50));
    await mouse.down(const Offset(200, 150));
    await mouse.up();
    expect(commands.map((c) => c['type']),
        ['mouse_down', 'mouse_up', 'mouse_down', 'mouse_up']);
  });
  testWidgets('pointer cancellation sends a release', (tester) async {
    await surface(tester);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.down(const Offset(200, 150));
    await mouse.cancel();
    expect(commands.last['type'], 'mouse_up');
    expect(pressed, isEmpty);
  });
}
