/// Платформа PWA по User-Agent (инцидент 2026-10-08 «Passwork падает в
/// код-фолбэк»): PWA ВСЕГДА сообщала 'web' — сервер не считал её мобильной,
/// ступень push каскада была недостижима, SAML всегда просил код.
///
/// Контракт с сервером (internal/delivery/app_push.go IsMobilePlatform):
///   web-ios / web-android — PWA на ТЕЛЕФОНЕ (живой WS/SSE такой строки =
///   полноценная пуш-ступень каскада, слепой пуш разрешён как нативным);
///   web — PWA на десктопе (немобильная, урок «фантомной мобильности»
///   v0.8.116: десктоп-PWA НЕ должен выглядеть телефоном).
library;

export 'web_platform_stub.dart' if (dart.library.html) 'web_platform_web.dart';

/// Честный детект платформы браузера по UA. Чистая функция — тестируется
/// без браузера. iPadOS 13+ по умолчанию шлёт desktop-Safari UA
/// («Macintosh»): отличаем iPad по touch-точкам (>1 у iPad, 0 у мышиного
/// macOS — Magic Trackpad не даёт navigator.maxTouchPoints).
String detectWebPlatform(String ua, {int maxTouchPoints = 0}) {
  final s = ua.toLowerCase();
  if (s.contains('iphone') || s.contains('ipod') || s.contains('ipad')) {
    return 'web-ios';
  }
  if (s.contains('macintosh') && maxTouchPoints > 1) {
    return 'web-ios'; // iPad в desktop-режиме UA
  }
  if (s.contains('android')) {
    return 'web-android';
  }
  return 'web';
}
