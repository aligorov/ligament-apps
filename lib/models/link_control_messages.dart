import 'dart:convert';

import 'package:flutter/material.dart';

/// Converts a point in the video viewport into normalized desktop coordinates.
/// Letterboxed areas are ignored except when releasing an already-pressed
/// input, where clamping prevents a stuck remote button.
Offset? linkNormalizedPointerPosition({
  required Offset position,
  required Size viewport,
  required int videoWidth,
  required int videoHeight,
  bool clampToVideo = false,
}) {
  if (!position.dx.isFinite ||
      !position.dy.isFinite ||
      !viewport.width.isFinite ||
      !viewport.height.isFinite ||
      viewport.width <= 0 ||
      viewport.height <= 0 ||
      videoWidth <= 0 ||
      videoHeight <= 0) {
    return null;
  }

  final videoAspect = videoWidth / videoHeight;
  final viewportAspect = viewport.width / viewport.height;
  var renderedWidth = viewport.width;
  var renderedHeight = viewport.height;
  var offsetX = 0.0;
  var offsetY = 0.0;
  if (viewportAspect > videoAspect) {
    renderedWidth = viewport.height * videoAspect;
    offsetX = (viewport.width - renderedWidth) / 2;
  } else {
    renderedHeight = viewport.width / videoAspect;
    offsetY = (viewport.height - renderedHeight) / 2;
  }

  final x = (position.dx - offsetX) / renderedWidth;
  final y = (position.dy - offsetY) / renderedHeight;
  if (!clampToVideo && (x < 0 || x > 1 || y < 0 || y > 1)) return null;
  return Offset(x.clamp(0.0, 1.0), y.clamp(0.0, 1.0));
}

Map<String, Object> linkPointerMessage({
  required String type,
  required Offset position,
  int? button,
}) {
  if (!const {'mouse_move', 'mouse_down', 'mouse_up'}.contains(type)) {
    throw ArgumentError.value(type, 'type', 'unsupported pointer message');
  }
  if (!position.dx.isFinite ||
      !position.dy.isFinite ||
      position.dx < 0 ||
      position.dx > 1 ||
      position.dy < 0 ||
      position.dy > 1) {
    throw ArgumentError.value(position, 'position', 'must be normalized');
  }
  if (type != 'mouse_move' && (button == null || button < 0 || button > 2)) {
    throw ArgumentError.value(button, 'button', 'must be 0, 1, or 2');
  }
  return <String, Object>{
    'type': type,
    'x': position.dx,
    'y': position.dy,
    if (button != null) 'button': button,
  };
}

String encodeLinkControlMessage(Map<String, Object?> message) =>
    jsonEncode(message);

/// Keyboard wire codes are Flutter logical IDs, never native VK/CGKeyCodes.
/// The 53-bit bound preserves exact integers on JSON/JavaScript peers.
class LinkKeyMessage {
  final String type;
  final String key;
  final int? keyCode;
  final String? char;

  const LinkKeyMessage._(this.type, this.key, this.keyCode, this.char);

  static LinkKeyMessage? tryParse(Map<String, Object?> input) {
    final type = input['type'];
    final key = input['key'];
    final code = input['keyCode'];
    final char = input['char'];
    if ((type != 'key_down' && type != 'key_up') ||
        key is! String ||
        key.isEmpty ||
        key.length > 64 ||
        (code != null &&
            (code is! int || code < 0 || code > 0x1fffffffffffff)) ||
        (char != null && (char is! String || char.length > 64))) {
      return null;
    }
    return LinkKeyMessage._(type as String, key, code as int?, char as String?);
  }

  factory LinkKeyMessage(
      {required String type, required String key, int? keyCode, String? char}) {
    final result =
        tryParse({'type': type, 'key': key, 'keyCode': keyCode, 'char': char});
    if (result == null) throw ArgumentError('Invalid Link keyboard message');
    return result;
  }

  Map<String, Object> toJson() => {
        'type': type,
        'key': key,
        if (keyCode != null) 'keyCode': keyCode!,
        if (char != null) 'char': char!,
      };

  LinkKeyMessage get release => LinkKeyMessage._('key_up', key, keyCode, char);

  /// Resolve native codes by name inside the injector, preserving text verbatim.
  void inject(
      void Function(
              {required String action,
              required String key,
              int? keyCode,
              String? char})
          keyAction) {
    keyAction(action: type == 'key_down' ? 'down' : 'up', key: key, char: char);
  }
}
