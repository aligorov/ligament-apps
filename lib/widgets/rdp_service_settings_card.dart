import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../i18n/app_strings.dart';
import '../services/auth_state.dart';
import '../services/rdp_endpoint_config_service.dart';

/// Карточка настроек RDP-службы на целевом ПК (§8 плана ремедиации).
/// Позволяет ввести одноразовый agent_key и передать его через UAC
/// в HKLM для запуска LigamentEndpointService.
class RdpServiceSettingsCard extends StatefulWidget {
  const RdpServiceSettingsCard({
    super.key,
    this.configService,
  });

  final RdpEndpointConfigService? configService;

  @override
  State<RdpServiceSettingsCard> createState() => _RdpServiceSettingsCardState();
}

class _RdpServiceSettingsCardState extends State<RdpServiceSettingsCard> {
  late final RdpEndpointConfigService _service;
  final TextEditingController _keyController = TextEditingController();

  RdpEndpointServiceStatus _status = RdpEndpointServiceStatus.unknown;
  bool _isLoading = false;
  String? _message;
  bool _isSuccess = false;

  @override
  void initState() {
    super.initState();
    _service = widget.configService ?? RdpEndpointConfigService();
    _refreshStatus();
  }

  @override
  void dispose() {
    _keyController.dispose();
    super.dispose();
  }

  Future<void> _refreshStatus() async {
    final s = await _service.getServiceStatus();
    if (mounted) {
      setState(() {
        _status = s;
      });
    }
  }

  Future<void> _applyKey(AuthState auth) async {
    final s = context.stringsRead;
    final key = _keyController.text.trim();
    if (key.isEmpty) {
      setState(() {
        _message = s.rdpServiceEmptyKey;
        _isSuccess = false;
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _message = null;
    });

    try {
      final ok = await _service.configureEndpointService(
        agentKey: key,
        serverUrl: auth.serverUrl,
      );

      // Немедленно очищаем контроллер — секрет не задерживается в памяти UI
      _keyController.clear();

      if (mounted) {
        if (ok) {
          setState(() {
            _message = s.rdpServiceConfigSuccess;
            _isSuccess = true;
          });
          // Даем службе запуститься и проверяем статус
          await Future.delayed(const Duration(seconds: 2));
          await _refreshStatus();
          // Обновляем список целей
          await auth.loadRdpTargets();
        } else {
          setState(() {
            _message = s.rdpServiceConfigError;
            _isSuccess = false;
          });
        }
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!kIsWeb && !Platform.isWindows && widget.configService == null) {
      return const SizedBox.shrink();
    }

    final s = context.strings;
    final auth = context.watch<AuthState>();

    String statusText;
    Color statusColor;
    switch (_status) {
      case RdpEndpointServiceStatus.running:
        statusText = s.rdpServiceStatusRunning;
        statusColor = Colors.greenAccent;
        break;
      case RdpEndpointServiceStatus.stopped:
        statusText = s.rdpServiceStatusStopped;
        statusColor = Colors.amber;
        break;
      case RdpEndpointServiceStatus.notInstalled:
        statusText = s.rdpServiceStatusNotInstalled;
        statusColor = const Color(0xFF94A3B8);
        break;
      default:
        statusText = s.rdpServiceStatusUnknown;
        statusColor = const Color(0xFF64748B);
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF334155)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.desktop_windows_outlined, color: Color(0xFF38BDF8), size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  s.rdpServiceSettingsTitle,
                  style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 14),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.refresh, size: 18, color: Color(0xFF38BDF8)),
                onPressed: _isLoading ? null : _refreshStatus,
                tooltip: s.refresh,
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            s.rdpServiceSettingsDesc,
            style: const TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
          ),
          const SizedBox(height: 12),
          _infoRow(s.rdpServiceComputerName, _service.localHostname, Colors.white),
          const SizedBox(height: 6),
          _infoRow(s.rdpServiceStatusLabel, statusText, statusColor),
          const SizedBox(height: 16),
          Text(
            s.rdpServiceAgentKeyLabel,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFFCBD5E1)),
          ),
          const SizedBox(height: 6),
          TextField(
            key: const Key('rdpAgentKeyField'),
            controller: _keyController,
            obscureText: true,
            enableInteractiveSelection: true,
            // Запрет копирования секрета обратно из поля
            contextMenuBuilder: (context, editableTextState) {
              final buttonItems = editableTextState.contextMenuButtonItems
                  .where((item) => item.type == ContextMenuButtonType.paste)
                  .toList();
              return AdaptiveTextSelectionToolbar.buttonItems(
                anchors: editableTextState.contextMenuAnchors,
                buttonItems: buttonItems,
              );
            },
            style: const TextStyle(color: Colors.white, fontSize: 13, fontFamily: 'monospace'),
            decoration: InputDecoration(
              hintText: s.rdpServiceAgentKeyHint,
              hintStyle: const TextStyle(color: Color(0xFF64748B), fontSize: 13),
              filled: true,
              fillColor: const Color(0xFF0F172A),
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: Color(0xFF334155)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: Color(0xFF334155)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: Color(0xFF38BDF8)),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            s.rdpServiceAdminNotice,
            style: const TextStyle(fontSize: 11, color: Color(0xFF64748B)),
          ),
          if (_message != null) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: _isSuccess
                    ? const Color(0xFF10B981).withValues(alpha: 0.15)
                    : Colors.redAccent.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: _isSuccess ? Colors.greenAccent : Colors.redAccent,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    _isSuccess ? Icons.check_circle_outline : Icons.error_outline,
                    size: 16,
                    color: _isSuccess ? Colors.greenAccent : Colors.redAccent,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _message!,
                      style: TextStyle(
                        fontSize: 12,
                        color: _isSuccess ? Colors.greenAccent : Colors.redAccent,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              key: const Key('rdpConnectThisPcBtn'),
              onPressed: _isLoading ? null : () => _applyKey(auth),
              icon: _isLoading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.link, size: 18),
              label: Text(s.rdpServiceConnectThisPcBtn),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF2563EB),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _infoRow(String label, String value, Color color) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: const TextStyle(fontSize: 13, color: Color(0xFF94A3B8))),
        Text(
          value,
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: color),
        ),
      ],
    );
  }
}
