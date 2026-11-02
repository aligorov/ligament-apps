import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../i18n/app_strings.dart';
import '../services/link_windows_security.dart';

/// Элемент файловой системы (локальный или удалённый)
class FsEntry {
  final String name;
  final String path;
  final bool isDir;
  final int size;
  final DateTime? modified;

  const FsEntry({
    required this.name,
    required this.path,
    required this.isDir,
    required this.size,
    this.modified,
  });

  factory FsEntry.fromMap(Map<String, dynamic> map, String parentDir, {bool isWindows = false}) {
    final name = map['name']?.toString() ?? '';
    final isDir = map['is_dir'] == true;
    final size = (map['size'] as num?)?.toInt() ?? 0;
    final modMs = (map['modified'] as num?)?.toInt();
    final sep = isWindows ? '\\' : '/';
    final fullPath = parentDir.endsWith(sep) || parentDir.endsWith('/') || parentDir.endsWith('\\')
        ? '$parentDir$name'
        : '$parentDir$sep$name';

    return FsEntry(
      name: name,
      path: fullPath,
      isDir: isDir,
      size: size,
      modified: modMs != null && modMs > 0 ? DateTime.fromMillisecondsSinceEpoch(modMs) : null,
    );
  }
}

/// Реактивное состояние передачи файла для диалога и строки состояния.
class LinkFileTransferState {
  final String id;
  final String filename;
  final int totalSize;
  final int transferredBytes;
  final double progress; // 0.0 .. 1.0
  final bool isOutgoing; // true = upload, false = download
  final String status; // 'sending', 'receiving', 'waiting_ack', 'completed', 'error', 'cancelled'
  final String? speedText;
  final String? errorMessage;
  final String? targetDir;

  const LinkFileTransferState({
    required this.id,
    required this.filename,
    required this.totalSize,
    required this.transferredBytes,
    required this.progress,
    required this.isOutgoing,
    required this.status,
    this.speedText,
    this.errorMessage,
    this.targetDir,
  });

  bool get isActive =>
      status == 'sending' || status == 'receiving' || status == 'waiting_ack';
  bool get isCompleted => status == 'completed';
  bool get isFailed => status == 'error' || status == 'cancelled';
}

/// Двухпанельный диалог файлового менеджера для сессии Ligament LINK.
class LinkFileManagerDialog extends StatefulWidget {
  final bool Function(Map<String, dynamic> msg) sendDataMessage;
  final Stream<Map<String, dynamic>> fsStream;
  final Future<void> Function(File localFile, String remoteDestDir) onUploadFile;
  final void Function(String remoteFilePath, String localDestDir) onDownloadFile;
  final ValueListenable<LinkFileTransferState?>? transferStateListenable;
  final double? transferProgress;
  final String? transferStatusText;
  final VoidCallback? onCancelTransfer;

  const LinkFileManagerDialog({
    super.key,
    required this.sendDataMessage,
    required this.fsStream,
    required this.onUploadFile,
    required this.onDownloadFile,
    this.transferStateListenable,
    this.transferProgress,
    this.transferStatusText,
    this.onCancelTransfer,
  });

  @override
  State<LinkFileManagerDialog> createState() => _LinkFileManagerDialogState();
}

class _LinkFileManagerDialogState extends State<LinkFileManagerDialog> {
  // Локальная файловая система
  String _localPath = '';
  List<FsEntry> _localEntries = [];
  FsEntry? _selectedLocalEntry;
  bool _isLoadingLocal = false;
  List<String> _localDrives = [];

  // Удалённая файловая система
  String _remotePath = '';
  String _remoteParent = '';
  List<FsEntry> _remoteEntries = [];
  FsEntry? _selectedRemoteEntry;
  bool _isLoadingRemote = false;
  String? _remoteError;
  List<String> _remoteDrives = [];
  String? _lastCompletedTransferId;

  StreamSubscription<Map<String, dynamic>>? _fsSub;
  Timer? _remoteRequestTimeoutTimer;
  int _reqCounter = 0;
  final Map<String, Completer<Map<String, dynamic>>> _pendingRequests = {};

  final DateFormat _dateFormat = DateFormat('yyyy-MM-dd HH:mm');

  @override
  void initState() {
    super.initState();
    _initLocalFs();
    _fsSub = widget.fsStream.listen(_handleFsMessage);
    widget.transferStateListenable?.addListener(_onTransferStateChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _requestRemoteList('');
    });
  }

  @override
  void dispose() {
    widget.transferStateListenable?.removeListener(_onTransferStateChanged);
    _remoteRequestTimeoutTimer?.cancel();
    _fsSub?.cancel();
    for (final completer in _pendingRequests.values) {
      if (!completer.isCompleted) {
        completer.completeError('disposed');
      }
    }
    _pendingRequests.clear();
    super.dispose();
  }

  void _onTransferStateChanged() {
    final state = widget.transferStateListenable?.value;
    if (state != null && state.isCompleted && _lastCompletedTransferId != state.id) {
      _lastCompletedTransferId = state.id;
      if (mounted) {
        if (state.isOutgoing) {
          _requestRemoteList(_remotePath);
        } else {
          _loadLocalDirectory(_localPath);
        }
      }
    }
  }

  void _handleFsMessage(Map<String, dynamic> msg) {
    _remoteRequestTimeoutTimer?.cancel();
    final reqId = (msg['req_id'] ?? msg['request_id'])?.toString();
    if (reqId != null && _pendingRequests.containsKey(reqId)) {
      _pendingRequests.remove(reqId)?.complete(msg);
    }

    final type = msg['type']?.toString();
    if (type == 'fs_list_ack') {
      final err = msg['error']?.toString();
      if (err != null) {
        if (mounted) {
          setState(() {
            _isLoadingRemote = false;
            _remoteError = err;
          });
        }
        return;
      }

      final path = msg['path']?.toString() ?? '';
      final parent = msg['parent']?.toString() ?? '';
      final rawEntries = msg['entries'] as List<dynamic>? ?? [];
      final rawDrives = msg['drives'] as List<dynamic>?;
      if (rawDrives != null && rawDrives.isNotEmpty) {
        _remoteDrives = rawDrives.map((e) => e.toString()).toList();
      }
      final isWin = path.contains('\\') || path.contains(':');
      final page = msg['page'] as int?;
      final totalPages = msg['total_pages'] as int?;
      final isFinal = msg['is_final'] == true || totalPages == null;

      final entries = rawEntries
          .whereType<Map<String, dynamic>>()
          .map((m) => FsEntry.fromMap(m, path, isWindows: isWin))
          .toList();

      if (mounted) {
        setState(() {
          _remotePath = path;
          _remoteParent = parent;
          if (page == null || page == 0) {
            _remoteEntries = entries;
          } else {
            _remoteEntries.addAll(entries);
          }
          _selectedRemoteEntry = null;
          _isLoadingRemote = !isFinal;
          _remoteError = null;
        });
      }
    } else if (type == 'fs_action_ack') {
      final action = msg['action']?.toString();
      final ok = msg['ok'] == true;
      if (ok) {
        _requestRemoteList(_remotePath);
      } else {
        final err = msg['error']?.toString() ?? 'action failed';
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Ошибка $action: $err')),
          );
        }
      }
    }
  }

  Future<void> _initLocalFs() async {
    setState(() => _isLoadingLocal = true);
    try {
      String startPath = '';
      if (!kIsWeb && Platform.isWindows) {
        _localDrives = LinkWindowsSecurity.getWindowsDrives();
        startPath = Platform.environment['USERPROFILE'] ??
            (_localDrives.isNotEmpty ? _localDrives.first : r'C:\');
      } else if (!kIsWeb && (Platform.isMacOS || Platform.isLinux)) {
        startPath = Platform.environment['HOME'] ?? '/';
      } else {
        startPath = '/';
      }
      await _loadLocalDirectory(startPath);
    } catch (_) {
      if (mounted) {
        setState(() => _isLoadingLocal = false);
      }
    }
  }

  Future<void> _loadLocalDirectory(String dirPath) async {
    setState(() {
      _isLoadingLocal = true;
      _selectedLocalEntry = null;
    });

    try {
      final dir = Directory(dirPath);
      final exists = await dir.exists();
      if (!exists) {
        if (mounted) setState(() => _isLoadingLocal = false);
        return;
      }

      final list = await dir.list().toList();
      final entries = <FsEntry>[];

      for (final entity in list) {
        final isDir = entity is Directory;
        int size = 0;
        DateTime? modified;
        try {
          final stat = await entity.stat();
          size = stat.size;
          modified = stat.modified;
        } catch (_) {}

        final name = entity.uri.pathSegments.isNotEmpty
            ? (entity.uri.pathSegments.last.isNotEmpty
                ? entity.uri.pathSegments.last
                : (entity.uri.pathSegments.length > 1
                    ? entity.uri.pathSegments[entity.uri.pathSegments.length - 2]
                    : entity.path))
            : entity.path;

        entries.add(FsEntry(
          name: name,
          path: entity.path,
          isDir: isDir,
          size: isDir ? 0 : size,
          modified: modified,
        ));
      }

      // Папки первыми, затем по алфавиту
      entries.sort((a, b) {
        if (a.isDir && !b.isDir) return -1;
        if (!a.isDir && b.isDir) return 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });

      if (mounted) {
        setState(() {
          _localPath = dir.path;
          _localEntries = entries;
          _isLoadingLocal = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoadingLocal = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка чтения локальной папки: $e')),
        );
      }
    }
  }

  void _requestRemoteList(String path) {
    _remoteRequestTimeoutTimer?.cancel();
    setState(() {
      _isLoadingRemote = true;
      _remoteError = null;
    });
    final reqId = 'req_${++_reqCounter}_${DateTime.now().millisecondsSinceEpoch}';
    final sent = widget.sendDataMessage({
      'type': 'fs_list',
      'path': path,
      'req_id': reqId,
    });
    if (!sent) {
      if (mounted) {
        setState(() {
          _isLoadingRemote = false;
          _remoteError = 'Канал передачи данных не активен';
        });
      }
      return;
    }
    // Таймаут на случай непредвиденной сетевой задержки или недоступности
    _remoteRequestTimeoutTimer = Timer(const Duration(seconds: 8), () {
      if (mounted && _isLoadingRemote) {
        setState(() {
          _isLoadingRemote = false;
          _remoteError = 'Таймаут получения списка файлов с удалённого хоста (8 сек)';
        });
      }
    });
  }

  void _navigateLocalUp() {
    if (_localPath.isEmpty) return;
    final parent = Directory(_localPath).parent.path;
    if (parent != _localPath) {
      _loadLocalDirectory(parent);
    }
  }

  void _navigateRemoteUp() {
    if (_remoteParent.isNotEmpty && _remoteParent != _remotePath) {
      _requestRemoteList(_remoteParent);
    }
  }

  Future<void> _createLocalFolder() async {
    final strings = context.stringsRead;
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(strings.fileManagerNewFolder),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Folder name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(strings.isRu ? 'Отмена' : 'Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
            child: Text(strings.isRu ? 'Создать' : 'Create'),
          ),
        ],
      ),
    );

    if (name != null && name.isNotEmpty) {
      final sep = Platform.pathSeparator;
      final newPath = '$_localPath$sep$name';
      try {
        await Directory(newPath).create();
        await _loadLocalDirectory(_localPath);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Ошибка создания папки: $e')),
          );
        }
      }
    }
  }

  Future<void> _createRemoteFolder() async {
    final strings = context.stringsRead;
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${strings.fileManagerNewFolder} (Remote)'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Folder name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(strings.isRu ? 'Отмена' : 'Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
            child: Text(strings.isRu ? 'Создать' : 'Create'),
          ),
        ],
      ),
    );

    if (name != null && name.isNotEmpty) {
      final isWin = _remotePath.contains('\\') || _remotePath.contains(':');
      final sep = isWin ? '\\' : '/';
      final newPath = _remotePath.endsWith(sep) ? '$_remotePath$name' : '$_remotePath$sep$name';
      final reqId = 'req_${++_reqCounter}';
      widget.sendDataMessage({
        'type': 'fs_mkdir',
        'path': newPath,
        'req_id': reqId,
      });
    }
  }

  Future<void> _deleteRemoteEntry(FsEntry entry) async {
    final strings = context.stringsRead;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(strings.fileManagerDelete),
        content: Text(strings.isRu
            ? 'Удалить "${entry.name}" на удалённом ПК?'
            : 'Delete "${entry.name}" on remote PC?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(strings.isRu ? 'Отмена' : 'Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(strings.isRu ? 'Удалить' : 'Delete',
                style: const TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      final reqId = 'req_${++_reqCounter}';
      widget.sendDataMessage({
        'type': 'fs_delete',
        'path': entry.path,
        'req_id': reqId,
      });
    }
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final strings = context.stringsRead;
    final isDark = theme.brightness == Brightness.dark;

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      backgroundColor: isDark ? const Color(0xFF0F172A) : Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: SizedBox(
        width: 1050,
        height: 680,
        child: Column(
          children: [
            // Заголовок
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9),
                borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
                border: Border(
                  bottom: BorderSide(
                    color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
                  ),
                ),
              ),
              child: Row(
                children: [
                  const Icon(Icons.folder_shared, color: Color(0xFF38BDF8), size: 22),
                  const SizedBox(width: 10),
                  Text(
                    strings.fileManagerTitle,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: isDark ? Colors.white : Colors.black87,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0284C7).withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: const Color(0xFF0284C7)),
                    ),
                    child: Text(
                      strings.isRu ? 'Лимит: до 1 ГБ' : 'Limit: up to 1 GB',
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xFF38BDF8),
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, size: 20),
                    tooltip: strings.isRu ? 'Закрыть' : 'Close',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),

            // Основная двухпанельная область
            Expanded(
              child: Row(
                children: [
                  // Левая панель: Локальный ПК
                  Expanded(
                    flex: 5,
                    child: _buildPane(
                      title: strings.fileManagerLocal,
                      isRemote: false,
                      path: _localPath,
                      entries: _localEntries,
                      selectedEntry: _selectedLocalEntry,
                      isLoading: _isLoadingLocal,
                      drives: _localDrives,
                      onNavigateUp: _navigateLocalUp,
                      onRefresh: () => _loadLocalDirectory(_localPath),
                      onCreateFolder: _createLocalFolder,
                      onSelectEntry: (entry) {
                        setState(() => _selectedLocalEntry = entry);
                      },
                      onOpenEntry: (entry) {
                        if (entry.isDir) {
                          _loadLocalDirectory(entry.path);
                        }
                      },
                    ),
                  ),

                  // Центральная панель действий (Отправить / Скачать)
                  Container(
                    width: 72,
                    decoration: BoxDecoration(
                      color: isDark ? const Color(0xFF1E293B) : const Color(0xFFF8FAFC),
                      border: Border.symmetric(
                        vertical: BorderSide(
                          color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
                        ),
                      ),
                    ),
                    child: widget.transferStateListenable != null
                        ? ValueListenableBuilder<LinkFileTransferState?>(
                            valueListenable: widget.transferStateListenable!,
                            builder: (ctx, transfer, _) {
                              final isBusy = transfer?.isActive ?? false;
                              return _buildTransferButtons(isDark, strings, isBusy);
                            },
                          )
                        : _buildTransferButtons(
                            isDark, strings, widget.transferProgress != null),
                  ),

                  // Правая панель: Удалённый ПК
                  Expanded(
                    flex: 5,
                    child: _buildPane(
                      title: strings.fileManagerRemote,
                      isRemote: true,
                      path: _remotePath,
                      entries: _remoteEntries,
                      selectedEntry: _selectedRemoteEntry,
                      isLoading: _isLoadingRemote,
                      drives: _remoteDrives,
                      errorMessage: _remoteError,
                      onNavigateUp: _navigateRemoteUp,
                      onRefresh: () => _requestRemoteList(_remotePath),
                      onCreateFolder: _createRemoteFolder,
                      onDeleteEntry: _selectedRemoteEntry != null
                          ? () => _deleteRemoteEntry(_selectedRemoteEntry!)
                          : null,
                      onSelectEntry: (entry) {
                        setState(() => _selectedRemoteEntry = entry);
                      },
                      onOpenEntry: (entry) {
                        if (entry.isDir) {
                          _requestRemoteList(entry.path);
                        }
                      },
                    ),
                  ),
                ],
              ),
            ),

            // Статусная строка и прогресс передачи файла
            _buildStatusBar(isDark, strings),
          ],
        ),
      ),
    );
  }

  Widget _buildPane({
    required String title,
    required bool isRemote,
    required String path,
    required List<FsEntry> entries,
    required FsEntry? selectedEntry,
    required bool isLoading,
    List<String> drives = const [],
    String? errorMessage,
    required VoidCallback onNavigateUp,
    required VoidCallback onRefresh,
    required VoidCallback onCreateFolder,
    VoidCallback? onDeleteEntry,
    required ValueChanged<FsEntry> onSelectEntry,
    required ValueChanged<FsEntry> onOpenEntry,
  }) {
    final theme = Theme.of(context);
    final strings = context.stringsRead;
    final isDark = theme.brightness == Brightness.dark;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Заголовок панели
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          color: isDark ? const Color(0xFF1E293B).withValues(alpha: 0.6) : const Color(0xFFF1F5F9),
          child: Row(
            children: [
              Icon(
                isRemote ? Icons.computer : Icons.laptop_chromebook,
                size: 16,
                color: isRemote ? const Color(0xFF10B981) : const Color(0xFF38BDF8),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.arrow_upward, size: 16),
                tooltip: strings.fileManagerUp,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                onPressed: onNavigateUp,
              ),
              IconButton(
                icon: const Icon(Icons.refresh, size: 16),
                tooltip: strings.fileManagerRefresh,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                onPressed: onRefresh,
              ),
              IconButton(
                icon: const Icon(Icons.create_new_folder_outlined, size: 16),
                tooltip: strings.fileManagerNewFolder,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                onPressed: onCreateFolder,
              ),
              if (onDeleteEntry != null)
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 16, color: Color(0xFFEF4444)),
                  tooltip: strings.fileManagerDelete,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                  onPressed: onDeleteEntry,
                ),
            ],
          ),
        ),

        // Поле пути и диски
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF0F172A) : Colors.white,
            border: Border(
              bottom: BorderSide(
                color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
              ),
            ),
          ),
          child: Row(
            children: [
              const Icon(Icons.folder_open, size: 14, color: Color(0xFF94A3B8)),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  path.isEmpty ? (isRemote ? '(Roots / Drives)' : '/') : path,
                  style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (drives.isNotEmpty) ...[
                const SizedBox(width: 6),
                for (final d in drives)
                  Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(4),
                      onTap: () {
                        if (isRemote) {
                          _requestRemoteList(d);
                        } else {
                          _loadLocalDirectory(d);
                        }
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(
                            color: path.toLowerCase().startsWith(d.toLowerCase())
                                ? (isRemote ? const Color(0xFF10B981) : const Color(0xFF38BDF8))
                                : Colors.transparent,
                            width: 1,
                          ),
                        ),
                        child: Text(
                          d,
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: path.toLowerCase().startsWith(d.toLowerCase())
                                ? (isRemote ? const Color(0xFF10B981) : const Color(0xFF38BDF8))
                                : (isDark ? Colors.white70 : Colors.black87),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ],
          ),
        ),

        // Таблица файлов
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          color: isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0),
          child: Row(
            children: [
              Expanded(
                flex: 6,
                child: Text(
                  strings.fileManagerName,
                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                ),
              ),
              Expanded(
                flex: 2,
                child: Text(
                  strings.fileManagerSize,
                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                  textAlign: TextAlign.right,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 3,
                child: Text(
                  strings.fileManagerModified,
                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                  textAlign: TextAlign.right,
                ),
              ),
            ],
          ),
        ),

        // Список элементов
        Expanded(
          child: isLoading
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        strings.fileManagerLoading,
                        style: const TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
                      ),
                    ],
                  ),
                )
              : errorMessage != null
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.error_outline,
                                size: 36, color: Color(0xFFEF4444)),
                            const SizedBox(height: 8),
                            Text(
                              'Ошибка: $errorMessage',
                              style: const TextStyle(
                                  color: Color(0xFFEF4444), fontSize: 12),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 12),
                            ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: isDark
                                    ? const Color(0xFF1E293B)
                                    : const Color(0xFFE2E8F0),
                                foregroundColor:
                                    isDark ? Colors.white : Colors.black87,
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 16, vertical: 8),
                              ),
                              icon: const Icon(Icons.refresh, size: 16),
                              label: Text(strings.fileManagerRefresh),
                              onPressed: onRefresh,
                            ),
                          ],
                        ),
                      ),
                    )
                  : entries.isEmpty
                      ? Center(
                          child: Text(
                            strings.fileManagerEmptyFolder,
                            style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
                          ),
                        )
                      : ListView.builder(
                          itemCount: entries.length,
                          itemBuilder: (ctx, idx) {
                            final item = entries[idx];
                            final isSelected = selectedEntry?.path == item.path;

                            return InkWell(
                              onTap: () => onSelectEntry(item),
                              onDoubleTap: () => onOpenEntry(item),
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                                color: isSelected
                                    ? (isDark
                                        ? const Color(0xFF0284C7).withValues(alpha: 0.3)
                                        : const Color(0xFFBAE6FD))
                                    : null,
                                child: Row(
                                  children: [
                                    Icon(
                                      item.isDir ? Icons.folder : Icons.insert_drive_file_outlined,
                                      size: 16,
                                      color: item.isDir
                                          ? const Color(0xFFF59E0B)
                                          : const Color(0xFF94A3B8),
                                    ),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      flex: 6,
                                      child: Text(
                                        item.name,
                                        style: const TextStyle(fontSize: 12),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    Expanded(
                                      flex: 2,
                                      child: Text(
                                        item.isDir ? '' : _formatBytes(item.size),
                                        style: const TextStyle(
                                          fontSize: 11,
                                          color: Color(0xFF94A3B8),
                                          fontFamily: 'monospace',
                                        ),
                                        textAlign: TextAlign.right,
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      flex: 3,
                                      child: Text(
                                        item.modified != null
                                            ? _dateFormat.format(item.modified!)
                                            : '',
                                        style: const TextStyle(
                                          fontSize: 10,
                                          color: Color(0xFF64748B),
                                        ),
                                        textAlign: TextAlign.right,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
        ),
      ],
    );
  }

  Widget _buildTransferButtons(bool isDark, AppStrings strings, bool isBusy) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Tooltip(
          message: strings.fileManagerUpload,
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(
              shape: const CircleBorder(),
              padding: const EdgeInsets.all(14),
              backgroundColor: const Color(0xFF0284C7),
              foregroundColor: Colors.white,
              disabledBackgroundColor:
                  isDark ? const Color(0xFF334155) : const Color(0xFFCBD5E1),
            ),
            onPressed: (!isBusy &&
                    _selectedLocalEntry != null &&
                    !_selectedLocalEntry!.isDir &&
                    _remotePath.isNotEmpty)
                ? () {
                    final file = File(_selectedLocalEntry!.path);
                    widget.onUploadFile(file, _remotePath);
                  }
                : null,
            child: const Icon(Icons.arrow_forward, size: 20),
          ),
        ),
        const SizedBox(height: 20),
        Tooltip(
          message: strings.fileManagerDownload,
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(
              shape: const CircleBorder(),
              padding: const EdgeInsets.all(14),
              backgroundColor: const Color(0xFF10B981),
              foregroundColor: Colors.white,
              disabledBackgroundColor:
                  isDark ? const Color(0xFF334155) : const Color(0xFFCBD5E1),
            ),
            onPressed: (!isBusy &&
                    _selectedRemoteEntry != null &&
                    !_selectedRemoteEntry!.isDir &&
                    _localPath.isNotEmpty)
                ? () {
                    widget.onDownloadFile(
                      _selectedRemoteEntry!.path,
                      _localPath,
                    );
                  }
                : null,
            child: const Icon(Icons.arrow_back, size: 20),
          ),
        ),
      ],
    );
  }

  Widget _buildStatusBar(bool isDark, AppStrings strings) {
    if (widget.transferStateListenable != null) {
      return ValueListenableBuilder<LinkFileTransferState?>(
        valueListenable: widget.transferStateListenable!,
        builder: (ctx, transfer, _) {
          return _buildStatusBarContent(isDark, strings, transfer);
        },
      );
    }
    LinkFileTransferState? fallbackTransfer;
    if (widget.transferProgress != null) {
      fallbackTransfer = LinkFileTransferState(
        id: '',
        filename: widget.transferStatusText ?? '',
        totalSize: 0,
        transferredBytes: 0,
        progress: widget.transferProgress ?? 0.0,
        isOutgoing: true,
        status: 'sending',
      );
    }
    return _buildStatusBarContent(isDark, strings, fallbackTransfer);
  }

  Widget _buildStatusBarContent(
    bool isDark,
    AppStrings strings,
    LinkFileTransferState? transfer,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9),
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(12)),
        border: Border(
          top: BorderSide(
            color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
          ),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (transfer != null && transfer.isActive) ...[
            Row(
              children: [
                Icon(
                  transfer.isOutgoing ? Icons.arrow_upward : Icons.arrow_downward,
                  size: 14,
                  color: transfer.isOutgoing
                      ? const Color(0xFF0284C7)
                      : const Color(0xFF10B981),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '${transfer.isOutgoing ? (strings.isRu ? "Отправка" : "Sending") : (strings.isRu ? "Загрузка" : "Receiving")}: ${transfer.filename}'
                    ' • ${_formatBytes(transfer.transferredBytes)} из ${_formatBytes(transfer.totalSize)}'
                    '${transfer.speedText != null && transfer.speedText!.isNotEmpty ? " • ${transfer.speedText}" : ""}',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${(transfer.progress * 100).toStringAsFixed(1)}%',
                  style: const TextStyle(
                    fontSize: 12,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF0284C7),
                  ),
                ),
                if (widget.onCancelTransfer != null) ...[
                  const SizedBox(width: 10),
                  InkWell(
                    onTap: widget.onCancelTransfer,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: const Color(0x1FEF4444),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: const Color(0x66EF4444)),
                      ),
                      child: Text(
                        strings.isRu ? 'Отмена' : 'Cancel',
                        style: const TextStyle(
                          fontSize: 11,
                          color: Color(0xFFEF4444),
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: transfer.progress.clamp(0.0, 1.0),
                minHeight: 6,
                backgroundColor:
                    isDark ? const Color(0xFF334155) : const Color(0xFFCBD5E1),
                valueColor: AlwaysStoppedAnimation<Color>(
                  transfer.isOutgoing
                      ? const Color(0xFF0284C7)
                      : const Color(0xFF10B981),
                ),
              ),
            ),
          ] else if (transfer != null && transfer.isCompleted) ...[
            Row(
              children: [
                const Icon(Icons.check_circle, size: 15, color: Color(0xFF10B981)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '✓ ${strings.isRu ? "Файл успешно передан" : "File transferred successfully"}: ${transfer.filename} (${_formatBytes(transfer.totalSize)})',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF10B981),
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ] else if (transfer != null && transfer.isFailed) ...[
            Row(
              children: [
                const Icon(Icons.error_outline, size: 15, color: Color(0xFFEF4444)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '✗ ${strings.isRu ? "Ошибка передачи файла" : "Transfer failed"}: ${transfer.filename}${transfer.errorMessage != null ? " (${transfer.errorMessage})" : ""}',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFFEF4444),
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ] else ...[
            Row(
              children: [
                Text(
                  _selectedLocalEntry != null
                      ? 'Local: ${_selectedLocalEntry!.name} (${_selectedLocalEntry!.isDir ? "Folder" : _formatBytes(_selectedLocalEntry!.size)})'
                      : 'Local: $_localPath',
                  style: const TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
                  overflow: TextOverflow.ellipsis,
                ),
                const Spacer(),
                Text(
                  _selectedRemoteEntry != null
                      ? 'Remote: ${_selectedRemoteEntry!.name} (${_selectedRemoteEntry!.isDir ? "Folder" : _formatBytes(_selectedRemoteEntry!.size)})'
                      : 'Remote: $_remotePath',
                  style: const TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
