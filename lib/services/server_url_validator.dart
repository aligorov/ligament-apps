import 'dart:io';

/// Централизованная валидация адреса сервера Ligament (VULN-27 / L-16 / K-4).
///
/// Единая проверка для экрана подключения (connect_screen) и для URL,
/// принудительно заданного GPO/MDM (auth_state): раньше GPO-адрес уходил
/// в ApiClient без валидации вообще, а экран допускал http для любого хоста,
/// начинающегося с «127.» (127.evil.example проходил проверку).
///
/// Правила:
///  - https:// — допустим для любого хоста;
///  - http://  — ТОЛЬКО loopback: точные литералы localhost / 127.0.0.1 / ::1
///    плюс весь диапазон IPv4 127.0.0.0/8 (локальная отладка);
///  - прочие схемы (ftp:, file:, без схемы и т.п.) — отклоняются.
enum ServerUrlError { empty, invalid, insecureHttp, unsupportedScheme }

/// Возвращает null, если URL допустим, иначе код ошибки для отображения.
ServerUrlError? validateServerUrl(String url) {
  final trimmed = url.trim();
  if (trimmed.isEmpty || trimmed == 'https://' || trimmed == 'http://') {
    return ServerUrlError.empty;
  }
  final uri = Uri.tryParse(trimmed);
  if (uri == null || !uri.hasScheme) {
    return ServerUrlError.invalid;
  }
  final scheme = uri.scheme.toLowerCase();
  if (scheme == 'https') {
    return uri.host.isEmpty ? ServerUrlError.invalid : null;
  }
  if (scheme == 'http') {
    if (uri.host.isEmpty) return ServerUrlError.invalid;
    return isLoopbackHost(uri.host) ? null : ServerUrlError.insecureHttp;
  }
  return ServerUrlError.unsupportedScheme;
}

/// Точный матч loopback-хоста: localhost, ::1 или IPv4 из 127.0.0.0/8.
/// Префиксного сравнения «127.» недостаточно: 127.evil.example — реальный
/// публичный домен, резолвящийся куда угодно (L-16/K-4).
bool isLoopbackHost(String host) {
  final h = host.toLowerCase();
  if (h == 'localhost' || h == '::1' || h == '[::1]') return true;
  final addr = InternetAddress.tryParse(h);
  if (addr == null) return false;
  if (addr.type == InternetAddressType.IPv4) {
    final raw = addr.rawAddress;
    return raw.length == 4 && raw[0] == 127;
  }
  return false;
}
