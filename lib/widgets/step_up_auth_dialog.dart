import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:local_auth/local_auth.dart';
import 'package:provider/provider.dart';

import '../i18n/app_strings.dart';
import '../services/auth_state.dart';

enum _StepState {
  selection,
  pushWaiting,
  totpInput,
  passkeyAuthenticating,
}

/// Универсальный диалог подтверждения Step-Up 2FA / запроса на второй фактор.
/// Поддерживает:
/// - Push с числом (Number Matching) на другое доверенное устройство (текущее исключается)
/// - Passkey / Биометрию (Touch ID / Windows Hello)
/// - Резервный ввод 6-значного кода TOTP
class StepUpVerificationDialog extends StatefulWidget {
  final String? title;
  final String? message;
  final String? clientIp;

  const StepUpVerificationDialog({
    super.key,
    this.title,
    this.message,
    this.clientIp,
  });

  /// Статический хелпер для вызова диалога из любого экрана.
  static Future<String?> show(
    BuildContext context, {
    String? title,
    String? message,
    String? clientIp,
  }) {
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => StepUpVerificationDialog(
        title: title,
        message: message,
        clientIp: clientIp,
      ),
    );
  }

  @override
  State<StepUpVerificationDialog> createState() => _StepUpVerificationDialogState();
}

class _StepUpVerificationDialogState extends State<StepUpVerificationDialog> {
  _StepState _state = _StepState.selection;
  bool _isLoading = true;
  String? _error;

  // Опции от сервера
  String _effectiveClientIp = '';
  bool _hasTotp = true;
  bool _hasPasskey = false;
  List<Map<String, dynamic>> _devices = [];

  // Состояние Push с Number Matching
  String? _activeChallengeId;
  String? _activeNumberMatch;
  Map<String, dynamic>? _targetDevice;
  int _secondsLeft = 60;
  Timer? _countdownTimer;
  Timer? _pollTimer;

  // Контроллер TOTP
  final _totpController = TextEditingController();
  bool _isSubmittingTotp = false;

  @override
  void initState() {
    super.initState();
    _loadOptions();
  }

  @override
  void dispose() {
    _stopTimers();
    _totpController.dispose();
    super.dispose();
  }

  void _stopTimers() {
    _countdownTimer?.cancel();
    _countdownTimer = null;
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  Future<void> _loadOptions() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    final auth = context.read<AuthState>();
    try {
      final opts = await auth.getStepUpOptions();
      if (!mounted) return;

      final ip = opts['client_ip']?.toString() ?? widget.clientIp ?? auth.clientIp ?? '—';
      final hasTotp = opts['has_totp'] == true;
      final hasPasskey = opts['has_passkey'] == true;
      final rawDevices = opts['devices'];
      final List<Map<String, dynamic>> parsedDevices = [];
      if (rawDevices is List) {
        for (final item in rawDevices) {
          if (item is Map) {
            parsedDevices.add(Map<String, dynamic>.from(item));
          }
        }
      }

      setState(() {
        _effectiveClientIp = ip;
        _hasTotp = hasTotp;
        _hasPasskey = hasPasskey;
        _devices = parsedDevices;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _effectiveClientIp = widget.clientIp ?? auth.clientIp ?? '—';
        _hasTotp = true;
        _isLoading = false;
      });
    }
  }

  Future<void> _startPush(Map<String, dynamic> device) async {
    final deviceId = device['id']?.toString() ?? '';
    if (deviceId.isEmpty) return;

    final auth = context.read<AuthState>();
    setState(() {
      _isLoading = true;
      _error = null;
      _targetDevice = device;
    });

    try {
      final res = await auth.beginStepUpPush(deviceId);
      if (!mounted) return;

      final challengeId = res['challenge_id']?.toString();
      final numberMatch = res['number_match']?.toString();
      final ttl = (res['expires_in_seconds'] as int?) ?? 60;

      if (challengeId == null || numberMatch == null) {
        throw StateError('Invalid server response');
      }

      setState(() {
        _activeChallengeId = challengeId;
        _activeNumberMatch = numberMatch;
        _secondsLeft = ttl;
        _isLoading = false;
        _state = _StepState.pushWaiting;
      });

      _startPushTimers(challengeId);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  void _startPushTimers(String challengeId) {
    _stopTimers();

    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() {
        if (_secondsLeft > 0) {
          _secondsLeft--;
        } else {
          _stopTimers();
          _error = context.stringsRead.stepUpRequestExpired;
        }
      });
    });

    _pollTimer = Timer.periodic(const Duration(milliseconds: 1200), (timer) async {
      if (!mounted) {
        timer.cancel();
        return;
      }
      final auth = context.read<AuthState>();
      try {
        final poll = await auth.pollStepUpPush(challengeId);
        if (!mounted) return;

        final status = poll['status']?.toString();
        if (status == 'approved') {
          _stopTimers();
          final token = poll['stepup_token']?.toString();
          if (token != null && token.isNotEmpty) {
            Navigator.of(context).pop(token);
          }
        } else if (status == 'denied') {
          _stopTimers();
          setState(() {
            _error = context.stringsRead.stepUpRequestDenied;
          });
        } else if (status == 'cancelled') {
          _stopTimers();
          setState(() {
            _state = _StepState.selection;
          });
        } else if (status == 'expired') {
          _stopTimers();
          setState(() {
            _error = context.stringsRead.stepUpRequestExpired;
          });
        }
      } catch (_) {}
    });
  }

  Future<void> _cancelActivePush() async {
    _stopTimers();
    if (_activeChallengeId != null) {
      final auth = context.read<AuthState>();
      await auth.cancelStepUpPush(_activeChallengeId!);
    }
    if (mounted) {
      setState(() {
        _activeChallengeId = null;
        _activeNumberMatch = null;
        _targetDevice = null;
        _error = null;
        _state = _StepState.selection;
      });
    }
  }

  Future<void> _handlePasskey() async {
    setState(() {
      _state = _StepState.passkeyAuthenticating;
      _error = null;
    });

    final s = context.stringsRead;
    try {
      final localAuth = LocalAuthentication();
      final isSupported = await localAuth.isDeviceSupported();
      if (!isSupported) {
        throw StateError(s.isRu ? 'Биометрия не поддерживается на этом ПК' : 'Biometrics not supported on this PC');
      }

      final didAuth = await localAuth.authenticate(
        localizedReason: s.isRu
            ? 'Подтвердите операцию (Touch ID / Windows Hello / Passkey)'
            : 'Confirm operation (Touch ID / Windows Hello / Passkey)',
        options: const AuthenticationOptions(biometricOnly: false, stickyAuth: true),
      );

      if (!didAuth) {
        if (mounted) {
          setState(() {
            _state = _StepState.selection;
          });
        }
        return;
      }

      if (!mounted) return;
      final auth = context.read<AuthState>();
      final token = await auth.verifyStepUp(passkey: true);
      if (mounted) {
        Navigator.of(context).pop(token);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _state = _StepState.selection;
          _error = e.toString().replaceFirst('Exception: ', '');
        });
      }
    }
  }

  Future<void> _submitTotp() async {
    final code = _totpController.text.trim();
    if (code.isEmpty || code.length != 6) {
      setState(() {
        _error = context.stringsRead.stepUpCodePlaceholder;
      });
      return;
    }

    setState(() {
      _isSubmittingTotp = true;
      _error = null;
    });

    final auth = context.read<AuthState>();
    try {
      final token = await auth.verifyStepUp(totpCode: code);
      if (mounted) {
        Navigator.of(context).pop(token);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isSubmittingTotp = false;
          _error = e.toString().replaceFirst('Exception: ', '');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.strings;

    return AlertDialog(
      backgroundColor: const Color(0xFF0F172A),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: Color(0xFFD97706), width: 1.5),
      ),
      titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 10),
      contentPadding: const EdgeInsets.fromLTRB(20, 10, 20, 20),
      title: Row(
        children: [
          const Icon(Icons.security, color: Color(0xFFF59E0B), size: 24),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              widget.title ?? s.stepUpTitle,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_error != null) ...[
                Container(
                  padding: const EdgeInsets.all(10),
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: Colors.redAccent.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.redAccent.withValues(alpha: 0.5)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.error_outline, color: Colors.redAccent, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _error!,
                          style: const TextStyle(color: Colors.redAccent, fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              // Содержимое в зависимости от текущего состояния
              if (_isLoading)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 36),
                  child: Center(
                    child: CircularProgressIndicator(color: Color(0xFFF59E0B)),
                  ),
                )
              else if (_state == _StepState.selection)
                _buildSelectionView(s)
              else if (_state == _StepState.pushWaiting)
                _buildPushWaitingView(s)
              else if (_state == _StepState.totpInput)
                _buildTotpInputView(s)
              else if (_state == _StepState.passkeyAuthenticating)
                _buildPasskeyAuthenticatingView(s),
            ],
          ),
        ),
      ),
      actions: _buildActions(s),
    );
  }

  Widget _buildSelectionView(AppStrings s) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          widget.message ?? s.stepUpContext(_effectiveClientIp),
          style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
        ),
        const SizedBox(height: 16),

        // 1. Секция устройств для Push с числом
        Row(
          children: [
            const Icon(Icons.phonelink_ring, size: 16, color: Color(0xFF38BDF8)),
            const SizedBox(width: 6),
            Text(
              s.stepUpDevicesHeader,
              style: const TextStyle(
                color: Color(0xFFCBD5E1),
                fontSize: 12,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),

        if (_devices.isEmpty)
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF1E293B),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFF334155)),
            ),
            child: Text(
              s.stepUpNoOtherDevices,
              style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
            ),
          )
        else
          ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: _devices.length,
            separatorBuilder: (_, __) => const SizedBox(height: 6),
            itemBuilder: (ctx, i) {
              final dev = _devices[i];
              return _buildDeviceTile(dev, s);
            },
          ),

        const SizedBox(height: 16),

        // 2. Быстрые и резервные способы
        Row(
          children: [
            const Icon(Icons.lock_clock, size: 16, color: Color(0xFFF59E0B)),
            const SizedBox(width: 6),
            Text(
              s.stepUpQuickHeader,
              style: const TextStyle(
                color: Color(0xFFCBD5E1),
                fontSize: 12,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),

        // Passkey / Биометрия
        if (_hasPasskey) ...[
          _buildMethodTile(
            icon: Icons.fingerprint,
            iconColor: const Color(0xFF38BDF8),
            title: s.stepUpPasskeyTitle,
            subtitle: s.stepUpPasskeySub,
            onTap: _handlePasskey,
          ),
          const SizedBox(height: 6),
        ],

        // TOTP
        if (_hasTotp) ...[
          _buildMethodTile(
            icon: Icons.pin,
            iconColor: const Color(0xFFF59E0B),
            title: s.stepUpTotpTitle,
            subtitle: s.stepUpTotpSub,
            onTap: () {
              setState(() {
                _error = null;
                _state = _StepState.totpInput;
              });
            },
          ),
        ],
      ],
    );
  }

  Widget _buildDeviceTile(Map<String, dynamic> dev, AppStrings s) {
    final name = dev['name']?.toString() ?? 'Device';
    final platform = (dev['platform']?.toString() ?? '').toLowerCase();
    final isOnline = dev['is_online'] == true;
    final lastIp = dev['last_ip']?.toString() ?? '';
    final lastSeenRaw = dev['last_seen_at']?.toString();

    String lastSeenStr = '';
    if (lastSeenRaw != null) {
      final dt = DateTime.tryParse(lastSeenRaw)?.toLocal();
      if (dt != null) {
        lastSeenStr = DateFormat('HH:mm (dd.MM)').format(dt);
      }
    }

    IconData devIcon = Icons.devices;
    if (platform == 'ios') {
      devIcon = Icons.phone_iphone;
    } else if (platform == 'android') {
      devIcon = Icons.phone_android;
    } else if (platform == 'macos') {
      devIcon = Icons.laptop_mac;
    } else if (platform == 'windows') {
      devIcon = Icons.desktop_windows;
    } else if (platform.contains('web')) {
      devIcon = Icons.language;
    }

    return Material(
      color: const Color(0xFF1E293B),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: () => _startPush(dev),
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isOnline ? const Color(0xFF10B981).withValues(alpha: 0.4) : const Color(0xFF334155),
            ),
          ),
          child: Row(
            children: [
              Icon(devIcon, color: isOnline ? const Color(0xFF10B981) : const Color(0xFF94A3B8), size: 24),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            name,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: const Color(0xFF334155),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            platform.toUpperCase(),
                            style: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 9, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        if (isOnline) ...[
                          const Icon(Icons.circle, color: Color(0xFF10B981), size: 8),
                          const SizedBox(width: 4),
                          Text(
                            s.stepUpDeviceOnline,
                            style: const TextStyle(color: Color(0xFF10B981), fontSize: 11, fontWeight: FontWeight.w500),
                          ),
                        ] else if (dev['has_push'] == true || dev['status'] == 'push_ready') ...[
                          const Icon(Icons.notifications_active, color: Color(0xFF38BDF8), size: 11),
                          const SizedBox(width: 4),
                          Text(
                            s.stepUpDevicePushReady,
                            style: const TextStyle(color: Color(0xFF38BDF8), fontSize: 11, fontWeight: FontWeight.w500),
                          ),
                        ] else ...[
                          const Icon(Icons.circle_outlined, color: Color(0xFF64748B), size: 8),
                          const SizedBox(width: 4),
                          Text(
                            s.stepUpDeviceLastSeen(lastSeenStr),
                            style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 11),
                          ),
                        ],
                        if (lastIp.isNotEmpty) ...[
                          const Text(' · ', style: TextStyle(color: Color(0xFF64748B), fontSize: 11)),
                          Text(lastIp, style: const TextStyle(color: Color(0xFF64748B), fontSize: 11)),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              const Icon(Icons.arrow_forward_ios, color: Color(0xFF64748B), size: 14),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMethodTile({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return Material(
      color: const Color(0xFF1E293B),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0xFF334155)),
          ),
          child: Row(
            children: [
              Icon(icon, color: iconColor, size: 24),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 11),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.arrow_forward_ios, color: Color(0xFF64748B), size: 14),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPushWaitingView(AppStrings s) {
    final devName = _targetDevice?['name']?.toString() ?? 'Устройство';
    final progress = _secondsLeft / 60.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const SizedBox(height: 8),
        Text(
          s.stepUpNumberMatchInstruction,
          style: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 13),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 16),

        // Большое число Number Matching
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 36, vertical: 16),
          decoration: BoxDecoration(
            color: const Color(0xFF1E293B),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFF59E0B), width: 2),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFFF59E0B).withValues(alpha: 0.2),
                blurRadius: 16,
                spreadRadius: 2,
              ),
            ],
          ),
          child: Text(
            _activeNumberMatch ?? '—',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 48,
              fontWeight: FontWeight.bold,
              letterSpacing: 4,
            ),
          ),
        ),
        const SizedBox(height: 20),

        // Прогресс-бар и статус
        LinearProgressIndicator(
          value: progress.clamp(0.0, 1.0),
          backgroundColor: const Color(0xFF334155),
          valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFFF59E0B)),
        ),
        const SizedBox(height: 10),

        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF38BDF8)),
                ),
                const SizedBox(width: 8),
                Text(
                  s.stepUpWaitingConfirmation,
                  style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
                ),
              ],
            ),
            Text(
              s.stepUpSecondsLeft(_secondsLeft),
              style: const TextStyle(color: Color(0xFFF59E0B), fontSize: 12, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          devName,
          style: const TextStyle(color: Color(0xFF64748B), fontSize: 11),
        ),
        const SizedBox(height: 16),

        // Кнопка смены способа
        TextButton(
          onPressed: _cancelActivePush,
          child: Text(
            s.stepUpChangeMethod,
            style: const TextStyle(color: Color(0xFF38BDF8), fontSize: 13),
          ),
        ),
      ],
    );
  }

  Widget _buildTotpInputView(AppStrings s) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          s.stepUpContext(_effectiveClientIp),
          style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _totpController,
          autofocus: true,
          keyboardType: TextInputType.number,
          maxLength: 6,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 28,
            letterSpacing: 8,
            fontWeight: FontWeight.bold,
          ),
          decoration: InputDecoration(
            counterText: '',
            hintText: '000000',
            hintStyle: const TextStyle(color: Color(0xFF475569)),
            filled: true,
            fillColor: const Color(0xFF1E293B),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: Color(0xFF334155)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: Color(0xFFF59E0B), width: 1.5),
            ),
          ),
          onSubmitted: (_) => _submitTotp(),
        ),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            TextButton(
              onPressed: () {
                setState(() {
                  _error = null;
                  _state = _StepState.selection;
                });
              },
              child: Text(
                s.stepUpChangeMethod,
                style: const TextStyle(color: Color(0xFF38BDF8), fontSize: 13),
              ),
            ),
            ElevatedButton(
              onPressed: _isSubmittingTotp ? null : _submitTotp,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFD97706),
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              child: _isSubmittingTotp
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : Text(s.stepUpConfirmWithCode, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildPasskeyAuthenticatingView(AppStrings s) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 36),
      child: Column(
        children: [
          CircularProgressIndicator(color: Color(0xFF38BDF8)),
          SizedBox(height: 16),
          Text(
            'Подтверждение биометрией…',
            style: TextStyle(color: Color(0xFFCBD5E1), fontSize: 14),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildActions(AppStrings s) {
    if (_state == _StepState.totpInput) {
      return [
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: Text(s.cancel, style: const TextStyle(color: Color(0xFF94A3B8))),
        ),
      ];
    }

    return [
      TextButton(
        onPressed: () {
          _stopTimers();
          if (_activeChallengeId != null) {
            context.read<AuthState>().cancelStepUpPush(_activeChallengeId!);
          }
          Navigator.of(context).pop(null);
        },
        child: Text(s.cancel, style: const TextStyle(color: Color(0xFF94A3B8))),
      ),
    ];
  }
}
