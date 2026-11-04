import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:provider/provider.dart';
import '../services/auth_state.dart';
import '../services/call_session_manager.dart';

/// Плавающий оверлей активного вызова поверх навигационного стека приложения.
/// Поддерживает полноэкранный режим (Fullscreen), компактный режим «картинка в картинке» (PiP),
/// отображение входящего вызова и рендеринг реального WebRTC видеопотока.
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

    final isIncoming = _call.status == CallStatus.incoming;
    final isCalling = _call.status == CallStatus.calling;
    final isRinging = _call.status == CallStatus.ringing;
    final isOffline = _call.status == CallStatus.offline;
    final isConnected = _call.status == CallStatus.connected;

    final hasRemoteVideo = isConnected &&
        _call.isVideo &&
        _call.remoteRenderer != null &&
        _call.remoteRenderer!.srcObject != null;

    return Positioned.fill(
      child: Material(
        color: hasRemoteVideo
            ? Colors.black
            : theme.colorScheme.surface.withValues(alpha: 0.98),
        child: SafeArea(
          child: Stack(
            children: [
              // 1. Полноэкранный видеопоток удалённого абонента (если видео активно)
              if (hasRemoteVideo)
                Positioned.fill(
                  child: RTCVideoView(
                    _call.remoteRenderer!,
                    objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                  ),
                ),

              // 2. Локальное превью камеры в верхнем правом углу
              if (isConnected &&
                  _call.isVideo &&
                  !_call.isCameraOff &&
                  _call.localRenderer != null &&
                  _call.localRenderer!.srcObject != null)
                Positioned(
                  top: 70,
                  right: 16,
                  width: 100,
                  height: 140,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.white24, width: 2),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: RTCVideoView(
                        _call.localRenderer!,
                        mirror: true,
                        objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                      ),
                    ),
                  ),
                ),

              // 3. Контент: Верхний бар + Центральный аватар + Нижняя панель
              Column(
                children: [
                  // Верхний бар
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    child: Row(
                      children: [
                        if (!isIncoming)
                          IconButton(
                            icon: Icon(
                              Icons.picture_in_picture_alt,
                              color: hasRemoteVideo ? Colors.white : null,
                            ),
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
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  color: hasRemoteVideo ? Colors.white : null,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              Text(
                                isIncoming
                                    ? 'Входящий вызов (Ligament ICE)...'
                                    : isCalling
                                        ? 'Гудки (ожидание ответа)...'
                                        : 'Разговор • ${_call.formattedDuration}',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: isIncoming
                                      ? Colors.green
                                      : isCalling
                                          ? theme.colorScheme.primary
                                          : (hasRemoteVideo
                                              ? Colors.white70
                                              : theme.colorScheme.outline),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: hasRemoteVideo
                                ? Colors.black54
                                : theme.colorScheme.primaryContainer,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.shield_outlined,
                                size: 14,
                                color: hasRemoteVideo ? Colors.greenAccent : theme.colorScheme.primary,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                'P2P ICE',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: hasRemoteVideo
                                      ? Colors.white
                                      : theme.colorScheme.onPrimaryContainer,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (!hasRemoteVideo) const Divider(height: 1),

                  // Центр: Аватар и статус (если видео нет)
                  Expanded(
                    child: hasRemoteVideo
                        ? const SizedBox.shrink()
                        : Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                CircleAvatar(
                                  radius: 54,
                                  backgroundColor: isIncoming
                                      ? Colors.green.withValues(alpha: 0.15)
                                      : theme.colorScheme.primaryContainer,
                                  foregroundColor: isIncoming
                                      ? Colors.green
                                      : theme.colorScheme.onPrimaryContainer,
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
                                  isIncoming
                                      ? (_call.isVideo
                                          ? '📹 Входящий видеовызов'
                                          : '📞 Входящий аудиовызов')
                                      : isOffline
                                          ? '❌ Абонент не в сети'
                                          : isRinging
                                              ? '📞 Идут гудки (вызов доставлен)...'
                                              : isCalling
                                                  ? '📞 Вызов абонента...'
                                                  : (_call.isVideo
                                                      ? '📹 Защищённый видеозвонок'
                                                      : '📞 Защищённый аудиозвонок'),
                                  style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                    color: isIncoming || isRinging
                                        ? Colors.green
                                        : isOffline
                                            ? theme.colorScheme.error
                                            : theme.colorScheme.outline,
                                  ),
                                ),
                                const SizedBox(height: 16),
                                if (isConnected)
                                  Text(
                                    _call.formattedDuration,
                                    style: TextStyle(
                                      fontSize: 20,
                                      fontWeight: FontWeight.w600,
                                      color: theme.colorScheme.primary,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                  ),

                  // Нижняя панель действий
                  if (isIncoming) ...[
                    // Кнопки Принять / Отклонить для входящего звонка
                    Padding(
                      padding: const EdgeInsets.only(bottom: 36, top: 12),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              FloatingActionButton.large(
                                heroTag: 'call_reject',
                                backgroundColor: theme.colorScheme.error,
                                foregroundColor: Colors.white,
                                onPressed: _call.rejectIncomingCall,
                                child: const Icon(Icons.call_end, size: 36),
                              ),
                              const SizedBox(height: 8),
                              const Text('Отклонить', style: TextStyle(fontWeight: FontWeight.w500)),
                            ],
                          ),
                          const SizedBox(width: 60),
                          Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              FloatingActionButton.large(
                                heroTag: 'call_accept',
                                backgroundColor: Colors.green,
                                foregroundColor: Colors.white,
                                onPressed: () {
                                  final auth = context.read<AuthState>();
                                  _call.acceptIncomingCall(iceServers: auth.iceServers);
                                },
                                child: Icon(_call.isVideo ? Icons.videocam : Icons.call, size: 36),
                              ),
                              const SizedBox(height: 8),
                              const Text('Принять', style: TextStyle(fontWeight: FontWeight.w500)),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ] else ...[
                    // Плавающая панель контролов для исходящего и активного звонка
                    Container(
                      margin: const EdgeInsets.all(24),
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                      decoration: BoxDecoration(
                        color: hasRemoteVideo
                            ? Colors.black87
                            : theme.colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(36),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.2),
                            blurRadius: 16,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (isConnected) ...[
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
                              IconButton.filledTonal(
                                icon: const Icon(Icons.flip_camera_ios),
                                tooltip: 'Переключить камеру',
                                onPressed: _call.switchCamera,
                              ),
                              const SizedBox(width: 12),
                            ],
                          ],
                          IconButton.filled(
                            style: IconButton.styleFrom(backgroundColor: theme.colorScheme.error),
                            icon: const Icon(Icons.call_end, color: Colors.white),
                            tooltip: isCalling ? 'Отменить вызов' : 'Завершить вызов',
                            onPressed: () => _call.endCall(notifyPeer: true),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
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
                          onTap: () => _call.endCall(notifyPeer: true),
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
