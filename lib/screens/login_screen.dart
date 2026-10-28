import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../api/client.dart';
import '../services/auth_state.dart';
import '../services/debug_log_service.dart';
import '../i18n/app_strings.dart';
import '../widgets/neural_mesh_background.dart';
import 'home_screen.dart';
import 'connect_screen.dart';

class LoginScreen extends StatefulWidget {
  final Map<String, dynamic> serverConfig;
  final DebugLogService? debugLogs;
  const LoginScreen({super.key, required this.serverConfig, this.debugLogs});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  DebugLogService get _debugLogs => widget.debugLogs ?? DebugLogService.instance;
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _codeController = TextEditingController();
  bool _obscurePassword = true;
  bool _isLoading = false;
  bool _requiresSecondFactor = false;
  bool _pushSent = false;
  String? _challengeId;
  String? _claimToken;
  Timer? _claimPollingTimer;
  bool _claimPollInFlight = false;
  int _claimGeneration = 0;
  AuthState? _auth;
  String? _error;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _auth = context.read<AuthState>();
  }

  void _stopClaimPolling() {
    _claimPollingTimer?.cancel();
    _claimPollingTimer = null;
    _claimPollInFlight = false;
  }

  void _cancelClaimPolling() {
    _claimGeneration++;
    _stopClaimPolling();
  }

  void _resetSecondFactor() {
    _debugLogs.record('ui.login.second_factor.cancelled');
    _cancelClaimPolling();
    _auth?.cancelLoginAttempts();
    setState(() {
      _requiresSecondFactor = false;
      _pushSent = false;
      _challengeId = null;
      _claimToken = null;
      _codeController.clear();
      _error = null;
    });
  }

  void _startClaimPolling() {
    _cancelClaimPolling();
    final generation = _claimGeneration;
    final challengeId = _challengeId;
    final claimToken = _claimToken;
    final auth = _auth;
    if (!mounted ||
        challengeId == null ||
        claimToken == null ||
        auth == null) {
      return;
    }

    _debugLogs.record('ui.login.claim_poll.started');
    var attempt = 0;
    _claimPollingTimer =
        Timer.periodic(const Duration(milliseconds: 1500), (timer) async {
      if (!mounted || generation != _claimGeneration) {
        timer.cancel();
        return;
      }
      // Медленный claim не накапливает параллельные HTTP-запросы на тиках.
      if (_claimPollInFlight) return;
      _claimPollInFlight = true;
      final watch = Stopwatch()..start();
      final pollAttempt = ++attempt;
      _debugLogs.record('ui.login.claim.started', fields: {'attempt': pollAttempt});
      try {
        final res = await auth.loginClaim(
          challengeId: challengeId,
          claimToken: claimToken,
        );

        if (!mounted || generation != _claimGeneration) {
          _debugLogs.record('ui.login.claim.cancelled', fields: {
            'reason': 'superseded', 'attempt': pollAttempt, 'duration_ms': watch.elapsedMilliseconds,
          });
          return;
        }

        final status = res['status']?.toString();
        final authenticated = res['token'] != null && auth.isLoggedIn && auth.token == res['token'];
        _debugLogs.record(
            res['token'] != null && !authenticated ? 'ui.login.claim.cancelled' : 'ui.login.claim.completed',
            fields: {
          'attempt': pollAttempt, 'duration_ms': watch.elapsedMilliseconds,
          'result': res['token'] != null ? (authenticated ? 'authenticated' : 'superseded') :
              (status == 'denied' ? 'denied' : (status == 'expired' ? 'expired' : 'pending')),
        });
        if (res['token'] != null) {
          timer.cancel();
          _claimPollingTimer = null;
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(builder: (_) => const HomeScreen()),
          );
        } else if (status == 'denied') {
          timer.cancel();
          _claimPollingTimer = null;
          setState(() {
            _pushSent = false;
            _error = context.stringsRead.errLoginDeniedOnDevice;
          });
        } else if (status == 'expired') {
          timer.cancel();
          _claimPollingTimer = null;
          setState(() {
            _pushSent = false;
            _error = context.stringsRead.errChallengeExpired;
          });
        }
      } on ApiException catch (e) {
        _debugLogs.record('ui.login.claim.failed', error: e, fields: {
          'attempt': pollAttempt, 'duration_ms': watch.elapsedMilliseconds,
        });
        if (!mounted || generation != _claimGeneration) return;
        if (e.code == 'challenge_denied' || e.code == 'denied') {
          timer.cancel();
          _claimPollingTimer = null;
          setState(() {
            _pushSent = false;
            _error = context.stringsRead.errLoginDeniedOnDevice;
          });
        } else if (e.code == 'challenge_expired' || e.code == 'expired') {
          timer.cancel();
          _claimPollingTimer = null;
          setState(() {
            _pushSent = false;
            _error = context.stringsRead.errChallengeExpired;
          });
        }
      } catch (e) {
        _debugLogs.record('ui.login.claim.failed', error: e, fields: {
          'attempt': pollAttempt, 'duration_ms': watch.elapsedMilliseconds,
        });
        debugPrint('login push claim error: $e');
      } finally {
        if (generation == _claimGeneration) _claimPollInFlight = false;
      }
    });
  }

  @override
  void dispose() {
    _cancelClaimPolling();
    // После успешной навигации LoginScreen разрушается, но готовую сессию
    // отменять нельзя. Незавершённый claim, наоборот, теряет право на login.
    if (_auth?.isLoggedIn != true) _auth?.cancelLoginAttempts();
    _usernameController.dispose();
    _passwordController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _handleLogin() async {
    final watch = Stopwatch()..start();
    final phase = _requiresSecondFactor ? 'second_factor' : 'password';
    _debugLogs.record('ui.login.submit', fields: {'phase': phase});
    if (_isLoading) {
      _debugLogs.record('ui.login.blocked', fields: {'reason': 'busy'});
      return;
    }
    _cancelClaimPolling();
    final generation = _claimGeneration;
    _auth?.cancelLoginAttempts();
    final s = context.stringsRead;
    final username = _usernameController.text.trim();
    final password = _passwordController.text;
    final code = _codeController.text.trim();

    if (username.isEmpty || password.isEmpty) {
      _debugLogs.record('ui.login.blocked', fields: {'reason': 'empty_credentials'});
      setState(() => _error = s.errFillUsernamePassword);
      return;
    }

    if (_requiresSecondFactor && code.isEmpty) {
      _debugLogs.record('ui.login.blocked', fields: {'reason': 'missing_second_factor'});
      setState(() => _error = s.errEnterVerificationCode);
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final auth = _auth ?? context.read<AuthState>();
      await auth.login(username, password, _requiresSecondFactor ? code : null);
      _debugLogs.record('ui.login.completed', fields: {
        'phase': phase,
        'result': auth.isLoggedIn && generation == _claimGeneration ? 'authenticated' : 'superseded',
        'duration_ms': watch.elapsedMilliseconds,
      });
      if (mounted && generation == _claimGeneration) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const HomeScreen()),
        );
      }
    } catch (e) {
      _debugLogs.record('ui.login.failed', error: e,
          fields: {'phase': phase, 'duration_ms': watch.elapsedMilliseconds});
      if (mounted && generation == _claimGeneration) {
        final msg = e.toString();
        setState(() {
          if (msg.contains('second_factor_required')) {
            if (!_requiresSecondFactor) {
              _requiresSecondFactor = true;
              if (e is ApiException && e.details != null) {
                _challengeId = e.details!['challenge_id']?.toString();
                _claimToken = e.details!['claim_token']?.toString();
                _pushSent = e.details!['push_sent'] == true;
              }
              if (_pushSent && _challengeId != null && _claimToken != null) {
                _error = null;
                _startClaimPolling();
              } else {
                _error = s.errSecondFactorRequired;
              }
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
    debugPrint('login error: $e');
    return '${s.loginErrorPrefix}: ${s.networkError}';
  }

  @override
  Widget build(BuildContext context) {
    final s = context.strings;
    final serverName = widget.serverConfig['server_name'] ?? 'Ligament 2FA';

    final auth = context.watch<AuthState>();
    final isGpoLocked = auth.gpo.enforcedServerUrl != null;
    final canPopRoute = Navigator.of(context).canPop();
    final canGoBack = !isGpoLocked || canPopRoute || _requiresSecondFactor;

    void handleBack() {
      _debugLogs.record('ui.login.back', fields: {
        'phase': _requiresSecondFactor ? 'second_factor' : 'password',
      });
      if (_requiresSecondFactor) {
        _resetSecondFactor();
      } else if (canPopRoute) {
        Navigator.of(context).pop();
      } else if (!isGpoLocked) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const ConnectScreen()),
        );
      }
    }

    return PopScope(
      canPop: canPopRoute && !_requiresSecondFactor,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (canGoBack) {
          handleBack();
        }
      },
      child: NeuralMeshBackground(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            elevation: 0,
            leading: canGoBack
                ? IconButton(
                    icon: const Icon(Icons.arrow_back, color: Colors.white),
                    tooltip: _requiresSecondFactor
                        ? s.btnBackToPassword
                        : (canPopRoute
                            ? (auth.isRu ? 'Назад' : 'Back')
                            : s.changeServer),
                    onPressed: handleBack,
                  )
                : null,
          ),
          body: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFF0F172A).withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: const Color(0xFF22D3EE).withValues(alpha: 0.22),
                      width: 1.2,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.45),
                        blurRadius: 28,
                        offset: const Offset(0, 8),
                      ),
                      BoxShadow(
                        color: const Color(0xFF22D3EE).withValues(alpha: 0.08),
                        blurRadius: 20,
                      ),
                    ],
                  ),
                  child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Image.asset(
                      'assets/icons/logo_light.png',
                      height: 72,
                      fit: BoxFit.contain,
                      semanticLabel: 'Ligament 2FA',
                    ),
                    if (serverName != 'Ligament 2FA' && serverName != 'Ligament') ...[
                      const SizedBox(height: 12),
                      Text(
                        serverName,
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: Colors.white),
                      ),
                    ],
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
                            onPressed: () {
                              _debugLogs.record('ui.login.password_visibility', fields: {'state': _obscurePassword ? 'visible' : 'hidden'});
                              setState(() => _obscurePassword = !_obscurePassword);
                            },
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
                              onPressed: _resetSecondFactor,
                              child: Text(s.btnChangeUser, style: const TextStyle(color: Color(0xFF38BDF8), fontSize: 12)),
                            ),
                          ],
                        ),
                      ),
                      if (_pushSent) ...[
                        const SizedBox(height: 16),
                        Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: const Color(0xFF0284C7).withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: const Color(0xFF38BDF8).withValues(alpha: 0.5)),
                          ),
                          child: Row(
                            children: [
                              const SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.5,
                                  color: Color(0xFF38BDF8),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      s.pushWaitingPrompt,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 13,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      s.pushWaitingHelp,
                                      style: const TextStyle(
                                        color: Color(0xFFBAE6FD),
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          s.orEnterCodePrompt,
                          style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
                        ),
                      ] else ...[
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
                      ],
                      const SizedBox(height: 16),
                      TextField(
                        controller: _codeController,
                        autofocus: !_pushSent,
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
                        onPressed: _isLoading ? null : _resetSecondFactor,
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
    ),
  ),
);
}
}
