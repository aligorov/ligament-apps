/// Stub-реализация для нативных сборок (Windows/Android/iOS/macOS/Linux):
/// браузерного окружения нет — UA пустой, детект вернёт платформу сборки.
String webUserAgent() => '';

/// maxTouchPoints браузера (0 в нативных сборках).
int webMaxTouchPoints() => 0;

/// Показ системного уведомления в браузере (stub для нативных платформ)
void showWebNotification(String title, String body) {}

/// Запрос разрешения на браузерные уведомления (stub для нативных платформ)
Future<bool> requestWebNotificationPermission() async => false;
