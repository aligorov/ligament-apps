/// Web-реализация (PWA): UA и touch-точки браузера.
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;

String webUserAgent() {
  try {
    return html.window.navigator.userAgent;
  } catch (_) {
    return '';
  }
}

int webMaxTouchPoints() {
  try {
    return html.window.navigator.maxTouchPoints ?? 0;
  } catch (_) {
    return 0;
  }
}
