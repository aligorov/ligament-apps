// ignore_for_file: deprecated_member_use, dangling_library_doc_comments, avoid_web_libraries_in_flutter
/// Web-реализация (PWA): UA и touch-точки браузера.
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

/// Показ системного уведомления в браузере (PWA / Web Notification API)
void showWebNotification(String title, String body) {
  try {
    if (html.Notification.permission == 'granted') {
      html.Notification(title, body: body, icon: '/icons/icon-192.png');
    } else if (html.Notification.permission != 'denied') {
      html.Notification.requestPermission().then((perm) {
        if (perm == 'granted') {
          html.Notification(title, body: body, icon: '/icons/icon-192.png');
        }
      });
    }
  } catch (_) {}
}

/// Запрос разрешения на браузерные уведомления (PWA / Web Notification API)
Future<bool> requestWebNotificationPermission() async {
  try {
    if (html.Notification.permission == 'granted') return true;
    final perm = await html.Notification.requestPermission();
    return perm == 'granted';
  } catch (_) {
    return false;
  }
}
