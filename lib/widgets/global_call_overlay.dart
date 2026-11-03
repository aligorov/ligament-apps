import 'package:flutter/material.dart';
import '../services/call_session_manager.dart';

/// Плавающий оверлей активного вызова поверх навигационного стека приложения.
/// Поддерживает полноэкранный режим (Fullscreen) и компактный режим «картинка в картинке» (PiP).
class GlobalCallOverlayWidget extends StatefulWidget {
  const GlobalCallOverlayWidget({super.key});

  @override
  State<GlobalCallOverlayWidget> createState() => _GlobalCallOverlayWidgetState();
}

class _GlobalCallOverlayWidgetState extends State<GlobalCallOverlayWidget> {
  final CallSessionManager _call = CallSessionManager.instance;
  Offset _pipPosition = const Offset(20, 40);

  @override
  void initState() {
    super.initState();
    _call.addListener(_onCallStateChanged);
  }

  @override
  void dispose() {
    _call.removeListener(_onCallStateChanged);
    super.dispose();
  }

  void _onCallStateChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (_call.displayMode == CallDisplayMode.hidden || _call.status == CallStatus.idle) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);

    if (_call.displayMode == CallDisplayMode.fullscreen) {
      return _buildFullscreenCall(theme);
    } else {
      return _buildPipOverlay(theme);
    }
  }

  Widget _buildFullscreenCall(ThemeData theme) {
    final initials = _call.chatTitle.isNotEmpty
        ? _call.chatTitle.substring(0, 1).toUpperCase()
        : 'C';

    return Positioned.fill(
      child: Material(
        color: theme.colorScheme.surface.withValues(alpha: 0.98),
        child: SafeArea(
          child: Column(
            children: [
              // Верхний бар
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.picture_in_picture_alt),
                      tooltip: 'Свернуть в мини-окно (PiP)',
                      onPressed: () => _call.setPip(true),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _call.chatTitle,
                            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            _call.status == CallStatus.calling
                                ? 'Соединение...'
                                : 'Разговор • ${_call.formattedDuration}',
                            style: TextStyle(
                              fontSize: 12,
                              color: _call.status == CallStatus.calling
                                  ? theme.colorScheme.primary
                                  : theme.colorScheme.outline,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.shield_outlined, size: 14, color: theme.colorScheme.primary),
                          const SizedBox(width: 4),
                          Text(
                            'P2P ICE',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: theme.colorScheme.onPrimaryContainer,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),

              // Центр: Видео или Аватар
              Expanded(
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      CircleAvatar(
                        radius: 54,
                        backgroundColor: theme.colorScheme.primaryContainer,
                        foregroundColor: theme.colorScheme.onPrimaryContainer,
                        child: Text(
                          initials,
                          style: const TextStyle(fontSize: 44, fontWeight: FontWeight.bold),
                        ),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        _call.chatTitle,
                        style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _call.isVideo ? 'Защищённый видеозвонок' : 'Защищённый аудиозвонок',
                        style: TextStyle(fontSize: 13, color: theme.colorScheme.outline),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        _call.formattedDuration,
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // Нижняя плавающая панель контролов
              Container(
                margin: const EdgeInsets.all(24),
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(36),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.1),
                      blurRadius: 16,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton.filledTonal(
                      icon: Icon(_call.isMuted ? Icons.mic_off : Icons.mic),
                      tooltip: _call.isMuted ? 'Включить микрофон' : 'Выключить микрофон',
                      onPressed: _call.toggleMute,
                    ),
                    const SizedBox(width: 12),
                    if (_call.isVideo) ...[
                      IconButton.filledTonal(
                        icon: Icon(_call.isCameraOff ? Icons.videocam_off : Icons.videocam),
                        tooltip: _call.isCameraOff ? 'Включить камеру' : 'Выключить камеру',
                        onPressed: _call.toggleCamera,
                      ),
                      const SizedBox(width: 12),
                    ],
                    IconButton.filledTonal(
                      icon: Icon(_call.isScreenSharing ? Icons.stop_screen_share : Icons.screen_share),
                      tooltip: _call.isScreenSharing ? 'Остановить показ' : 'Демонстрация экрана',
                      onPressed: _call.toggleScreenShare,
                    ),
                    const SizedBox(width: 16),
                    IconButton.filled(
                      style: IconButton.styleFrom(backgroundColor: theme.colorScheme.error),
                      icon: const Icon(Icons.call_end, color: Colors.white),
                      tooltip: 'Завершить вызов',
                      onPressed: _call.endCall,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPipOverlay(ThemeData theme) {
    final screenSize = MediaQuery.of(context).size;
    final initials = _call.chatTitle.isNotEmpty
        ? _call.chatTitle.substring(0, 1).toUpperCase()
        : 'C';

    return Positioned(
      right: _pipPosition.dx,
      bottom: _pipPosition.dy,
      child: GestureDetector(
        onPanUpdate: (details) {
          setState(() {
            _pipPosition = Offset(
              (_pipPosition.dx - details.delta.dx).clamp(10.0, screenSize.width - 210.0),
              (_pipPosition.dy - details.delta.dy).clamp(10.0, screenSize.height - 130.0),
            );
          });
        },
        child: Material(
          elevation: 8,
          borderRadius: BorderRadius.circular(16),
          color: theme.colorScheme.surfaceContainerHighest,
          child: Container(
            width: 200,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: theme.colorScheme.outlineVariant),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    CircleAvatar(
                      radius: 14,
                      backgroundColor: theme.colorScheme.primaryContainer,
                      foregroundColor: theme.colorScheme.onPrimaryContainer,
                      child: Text(
                        initials,
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _call.chatTitle,
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    InkWell(
                      onTap: () => _call.setPip(false),
                      borderRadius: BorderRadius.circular(12),
                      child: const Padding(
                        padding: EdgeInsets.all(4),
                        child: Icon(Icons.fullscreen, size: 18),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      _call.formattedDuration,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        InkWell(
                          onTap: _call.toggleMute,
                          borderRadius: BorderRadius.circular(12),
                          child: Padding(
                            padding: const EdgeInsets.all(4),
                            child: Icon(
                              _call.isMuted ? Icons.mic_off : Icons.mic,
                              size: 16,
                              color: _call.isMuted ? theme.colorScheme.error : null,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        InkWell(
                          onTap: _call.endCall,
                          borderRadius: BorderRadius.circular(12),
                          child: Container(
                            padding: const EdgeInsets.all(4),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.error,
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.call_end, size: 12, color: Colors.white),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
