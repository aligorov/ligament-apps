import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ligament_authenticator/models/link_control_messages.dart';
import 'package:ligament_authenticator/services/input_injector.dart';
import 'package:ligament_authenticator/services/support_service.dart';

void main() {
  group('sourceHandleParsing', () {
    test('parses numeric monitor and display handles robustly', () {
      expect(InputInjector.instance.parseSourceHandles('0'), [0]);
      expect(InputInjector.instance.parseSourceHandles('1'), [1]);
      expect(InputInjector.instance.parseSourceHandles('screen:1'), [1]);
      expect(InputInjector.instance.parseSourceHandles('screen:0:0'), [0, 0]);
      expect(InputInjector.instance.parseSourceHandles('HMONITOR:65539'), [65539]);
      expect(InputInjector.instance.parseSourceHandles('invalid'), isEmpty);
    });

    test('supportDebugMessageType allows screen switching telemetry labels', () {
      expect(supportDebugMessageType('screen_switched'), 'screen_switched');
      expect(supportDebugMessageType('switch_screen'), 'switch_screen');
      expect(supportDebugMessageType('screen_list'), 'screen_list');
    });
  });
  group('linkNormalizedPointerPosition', () {
    test('maps the rendered video inside a horizontal letterbox', () {
      const viewport = Size(1600, 900);
      final leftEdge = linkNormalizedPointerPosition(
        position: const Offset(200, 0),
        viewport: viewport,
        videoWidth: 1200,
        videoHeight: 900,
      );
      final center = linkNormalizedPointerPosition(
        position: const Offset(800, 450),
        viewport: viewport,
        videoWidth: 1200,
        videoHeight: 900,
      );

      expect(leftEdge, Offset.zero);
      expect(center, const Offset(0.5, 0.5));
      expect(
        linkNormalizedPointerPosition(
          position: const Offset(100, 450),
          viewport: viewport,
          videoWidth: 1200,
          videoHeight: 900,
        ),
        isNull,
      );
    });

    test('clamps release positions outside the letterboxed video', () {
      expect(
        linkNormalizedPointerPosition(
          position: const Offset(100, 450),
          viewport: const Size(1600, 900),
          videoWidth: 1200,
          videoHeight: 900,
          clampToVideo: true,
        ),
        Offset.zero.translate(0, 0.5),
      );
    });

    test('rejects invalid viewports and missing video dimensions', () {
      expect(
        linkNormalizedPointerPosition(
          position: Offset.zero,
          viewport: Size.zero,
          videoWidth: 1920,
          videoHeight: 1080,
        ),
        isNull,
      );
      expect(
        linkNormalizedPointerPosition(
          position: Offset.zero,
          viewport: const Size(100, 100),
          videoWidth: 0,
          videoHeight: 1080,
        ),
        isNull,
      );
    });
  });

  test('encodes only normalized pointer input messages', () {
    final message = linkPointerMessage(
      type: 'mouse_down',
      position: const Offset(0.25, 0.75),
      button: 2,
    );

    expect(jsonDecode(encodeLinkControlMessage(message)), <String, dynamic>{
      'type': 'mouse_down',
      'x': 0.25,
      'y': 0.75,
      'button': 2,
    });
    expect(
      () => linkPointerMessage(
        type: 'mouse_down',
        position: const Offset(1.1, 0.5),
        button: 0,
      ),
      throwsArgumentError,
    );
    expect(
      () => linkPointerMessage(
        type: 'mouse_down',
        position: const Offset(0.5, 0.5),
        button: 3,
      ),
      throwsArgumentError,
    );
  });
}
