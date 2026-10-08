/// Stub-реализация для нативных сборок (Windows/Android/iOS/macOS/Linux):
/// браузерного окружения нет — UA пустой, детект вернёт платформу сборки.
String webUserAgent() => '';

/// maxTouchPoints браузера (0 в нативных сборках).
int webMaxTouchPoints() => 0;
