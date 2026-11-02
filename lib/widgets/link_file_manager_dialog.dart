import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../i18n/app_strings.dart';

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

/// Двухпанельный диалог файлового менеджера для сессии Ligament LINK.
class LinkFileManagerDialog extends StatefulWidget {
  final bool Function(Map<String, dynamic> msg) sendDataMessage;
  final Stream<Map<String, dynamic>> fsStream;
  final Future<void> Function(File localFile, String remoteDestDir) onUploadFile;
  final void Function(String remoteFilePath, String localDestDir) onDownloadFile;
  final double? transferProgress;
  final String? transferStatusText;
  final VoidCallback? onCancelTransfer;

  const LinkFileManagerDialog({
    super.key,
    required this.sendDataMessage,
    required this.fsStream,
    required this.onUploadFile,
    required this.onDownloadFile,
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

  // Удалённая файловая система
  String _remotePath = '';
  String _remoteParent = '';
  List<FsEntry> _remoteEntries = [];
  FsEntry? _selectedRemoteEntry;
  bool _isLoadingRemote = false;
  String? _remoteError;

  StreamSubscription<Map<String, dynamic>>? _fsSub;
  int _reqCounter = 0;
  final Map<String, Completer<Map<String, dynamic>>> _pendingRequests = {};

  final DateFormat _dateFormat = DateFormat('yyyy-MM-dd HH:mm');

  @override
  void initState() {
    super.initState();
    _initLocalFs();
    _fsSub = widget.fsStream.listen(_handleFsMessage);
    _requestRemoteList('');
  }

  @override
  void dispose() {
    _fsSub?.cancel();
    for (final completer in _pendingRequests.values) {
      if (!completer.isCompleted) {
        completer.completeError('disposed');
      }
    }
    _pendingRequests.clear();
    super.dispose();
  }

  void _handleFsMessage(Map<String, dynamic> msg) {
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
        startPath = Platform.environment['USERPROFILE'] ?? 'C:\\';
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
    setState(() {
      _isLoadingRemote = true;
      _remoteError = null;
    });
    final reqId = 'req_${++_reqCounter}_${DateTime.now().millisecondsSinceEpoch}';
    widget.sendDataMessage({
      'type': 'fs_list',
      'path': path,
      'req_id': reqId,
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
    if (_remoteParent.isNotEmpty) {
      _requestRemoteList(_remoteParent);
    } else {
      _requestRemoteList('');
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
                    child: Column(
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
                            onPressed: (_selectedLocalEntry != null &&
                                    !_selectedLocalEntry!.isDir &&
                                    _remotePath.isNotEmpty &&
                                    widget.transferProgress == null)
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
                            onPressed: (_selectedRemoteEntry != null &&
                                    !_selectedRemoteEntry!.isDir &&
                                    _localPath.isNotEmpty &&
                                    widget.transferProgress == null)
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
                    ),
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
              Text(
                title,
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
              ),
              const Spacer(),
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

        // Поле пути
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
                      child: Text(
                        'Ошибка: $errorMessage',
                        style: const TextStyle(color: Color(0xFFEF4444), fontSize: 12),
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

  Widget _buildStatusBar(bool isDark, AppStrings strings) {
    final hasActiveTransfer = widget.transferProgress != null;

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
          if (hasActiveTransfer) ...[
            Row(
              children: [
                Expanded(
                  child: Text(
                    widget.transferStatusText ?? strings.consoleFileSending,
                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                  ),
                ),
                Text(
                  '${((widget.transferProgress ?? 0) * 100).toStringAsFixed(1)}%',
                  style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
                ),
                if (widget.onCancelTransfer != null) ...[
                  const SizedBox(width: 8),
                  InkWell(
                    onTap: widget.onCancelTransfer,
                    child: Text(
                      strings.isRu ? 'Отмена' : 'Cancel',
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xFFEF4444),
                        fontWeight: FontWeight.bold,
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
                value: widget.transferProgress,
                minHeight: 6,
                backgroundColor: isDark ? const Color(0xFF334155) : const Color(0xFFCBD5E1),
                valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF0284C7)),
              ),
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
