import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/auth_state.dart';
import '../i18n/app_strings.dart';
import 'home_screen.dart';

class LoginScreen extends StatefulWidget {
  final Map<String, dynamic> serverConfig;
  const LoginScreen({super.key, required this.serverConfig});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _codeController = TextEditingController();
  bool _obscurePassword = true;
  bool _isLoading = false;
  bool _requiresSecondFactor = false;
  String? _error;

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _handleLogin() async {
    final s = context.stringsRead;
    final username = _usernameController.text.trim();
    final password = _passwordController.text;
    final code = _codeController.text.trim();

    if (username.isEmpty || password.isEmpty) {
      setState(() => _error = s.errFillUsernamePassword);
      return;
    }

    if (_requiresSecondFactor && code.isEmpty) {
      setState(() => _error = s.errEnterVerificationCode);
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final auth = context.read<AuthState>();
      await auth.login(username, password, _requiresSecondFactor ? code : null);
      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const HomeScreen()),
        );
      }
    } catch (e) {
      if (mounted) {
        final msg = e.toString();
        setState(() {
          if (msg.contains('second_factor_required')) {
            if (!_requiresSecondFactor) {
              _requiresSecondFactor = true;
              _error = s.errSecondFactorRequired;
            } else {
              _error = s.errInvalidVerificationCode;
            }
          } else {
            _error = _translateLoginError(e, s);
          }
          _isLoading = false;
        });
      }
    }
  }

  String _translateLoginError(dynamic e, AppStrings s) {
    final msg = e.toString();
    if (msg.contains('invalid_credentials') || msg.contains('bad_credentials')) {
      return s.errInvalidCredentials;
    }
    if (msg.contains('bad_code') || msg.contains('second_factor_required')) {
      return s.errBadCodeOrExpired;
    }
    if (msg.contains('user_disabled')) {
      return s.errUserDisabled;
    }
    if (msg.contains('locked')) {
      return s.errAccountLocked;
    }
    if (msg.contains('rate_limited')) {
      return s.errRateLimited;
    }
    if (msg.contains('empty_credentials')) {
      return s.errFillUsernamePassword;
    }
    if (msg.contains('bad_json')) {
      return s.errBadJson;
    }
    return '${s.loginErrorPrefix}: $e';
  }

  @override
  Widget build(BuildContext context) {
    final s = context.strings;
    final serverName = widget.serverConfig['server_name'] ?? 'Ligament 2FA';

    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Card(
              color: const Color(0xFF1E293B),
              elevation: 8,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Icon(Icons.account_circle_outlined, size: 56, color: Color(0xFF38BDF8)),
                    const SizedBox(height: 16),
                    Text(
                      serverName,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.white),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      s.authWorkstation,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 13, color: Color(0xFF94A3B8)),
                    ),
                    const SizedBox(height: 28),
                    if (!_requiresSecondFactor) ...[
                      TextField(
                        controller: _usernameController,
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          labelText: s.corporateLogin,
                          labelStyle: const TextStyle(color: Color(0xFF94A3B8)),
                          prefixIcon: const Icon(Icons.person, color: Color(0xFF38BDF8)),
                          filled: true,
                          fillColor: const Color(0xFF0F172A),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: _passwordController,
                        obscureText: _obscurePassword,
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          labelText: s.password,
                          labelStyle: const TextStyle(color: Color(0xFF94A3B8)),
                          prefixIcon: const Icon(Icons.lock, color: Color(0xFF38BDF8)),
                          suffixIcon: IconButton(
                            icon: Icon(
                              _obscurePassword ? Icons.visibility : Icons.visibility_off,
                              color: const Color(0xFF94A3B8),
                            ),
                            onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                          ),
                          filled: true,
                          fillColor: const Color(0xFF0F172A),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        onSubmitted: (_) => _handleLogin(),
                      ),
                    ] else ...[
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        decoration: BoxDecoration(
                          color: const Color(0xFF0F172A),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: const Color(0xFF334155)),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.person, color: Color(0xFF38BDF8), size: 20),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                _usernameController.text.trim(),
                                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                              ),
                            ),
                            TextButton(
                              onPressed: () => setState(() {
                                _requiresSecondFactor = false;
                                _codeController.clear();
                                _error = null;
                              }),
                              child: Text(s.btnChangeUser, style: const TextStyle(color: Color(0xFF38BDF8), fontSize: 12)),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFF0284C7).withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: const Color(0xFF0284C7)),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.verified_user, color: Color(0xFF38BDF8), size: 20),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                s.secondFactorPrompt,
                                style: const TextStyle(color: Color(0xFFBAE6FD), fontSize: 12),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: _codeController,
                        autofocus: true,
                        keyboardType: TextInputType.number,
                        style: const TextStyle(color: Colors.white, fontSize: 18, letterSpacing: 4),
                        textAlign: TextAlign.center,
                        maxLength: 8,
                        decoration: InputDecoration(
                          labelText: s.codeFieldLabel,
                          counterText: '',
                          labelStyle: const TextStyle(color: Color(0xFF94A3B8)),
                          prefixIcon: const Icon(Icons.security, color: Color(0xFF38BDF8)),
                          filled: true,
                          fillColor: const Color(0xFF0F172A),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        onSubmitted: (_) => _handleLogin(),
                      ),
                    ],
                    if (_error != null) ...[
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFFEF4444).withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: const Color(0xFFEF4444)),
                        ),
                        child: Text(
                          _error!,
                          style: const TextStyle(color: Color(0xFFFCA5A5), fontSize: 13),
                        ),
                      ),
                    ],
                    const SizedBox(height: 24),
                    ElevatedButton(
                      onPressed: _isLoading ? null : _handleLogin,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF0284C7),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      child: _isLoading
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                            )
                          : Text(
                              _requiresSecondFactor ? s.btnConfirmAndLogin : s.btnLogin,
                              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                            ),
                    ),
                    if (_requiresSecondFactor) ...[
                      const SizedBox(height: 8),
                      TextButton(
                        onPressed: _isLoading
                            ? null
                            : () => setState(() {
                                  _requiresSecondFactor = false;
                                  _codeController.clear();
                                  _error = null;
                                }),
                        child: Text(s.btnBackToPassword, style: const TextStyle(color: Color(0xFF94A3B8))),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
