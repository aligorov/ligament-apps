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
