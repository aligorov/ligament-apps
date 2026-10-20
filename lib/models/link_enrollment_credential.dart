class LinkEnrollmentCredential {
  final String token;
  final DateTime expiresAt;

  const LinkEnrollmentCredential(
      {required this.token, required this.expiresAt});

  factory LinkEnrollmentCredential.fromJson(Map<String, dynamic> json) {
    final token = json['token'];
    final expiresAtValue = json['expires_at'];
    if (token is! String || !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(token)) {
      throw const FormatException('Invalid Link enrollment token');
    }
    if (expiresAtValue is! String) {
      throw const FormatException('Missing Link enrollment token expiry');
    }
    final expiresAt = DateTime.tryParse(expiresAtValue);
    if (expiresAt == null) {
      throw const FormatException('Invalid Link enrollment token expiry');
    }
    return LinkEnrollmentCredential(
      token: token,
      expiresAt: expiresAt.toUtc(),
    );
  }
}
