import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'support_operator_screen.dart';
import '../services/auth_state.dart';
import '../services/debug_log_service.dart';
import '../services/link_agent_binding_service.dart';
import '../widgets/neural_mesh_background.dart';

/// Lowercase search corpus built once per inventory snapshot. Filtering then
/// scans only the cached strings, rather than allocating/joining every host's
/// fields again on each keystroke.
class LinkHostSearchIndex {
  LinkHostSearchIndex(List<Map<String, dynamic>> hosts)
      : _entries = hosts.map(_SearchEntry.new).toList(growable: false),
        _emptyResult = hosts {
    for (var entryIndex = 0; entryIndex < _entries.length; entryIndex++) {
      final seen = <String>{};
      final text = _entries[entryIndex].searchable;
      for (var offset = 0; offset + 3 <= text.length; offset++) {
        final gram = text.substring(offset, offset + 3);
        if (!seen.add(gram)) continue;
        (_trigramPostings[gram] ??= <int>[]).add(entryIndex);
      }
    }
  }

  final List<_SearchEntry> _entries;
  final List<Map<String, dynamic>> _emptyResult;
  final Map<String, List<int>> _trigramPostings = <String, List<int>>{};

  int get length => _entries.length;

  List<Map<String, dynamic>> search(String query) {
    final tokens = query
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((token) => token.isNotEmpty)
        .toList(growable: false);
    if (tokens.isEmpty) return _emptyResult;

    List<int>? candidates;
    for (final token in tokens) {
      if (token.length < 3) continue;
      for (var offset = 0; offset + 3 <= token.length; offset++) {
        final postings = _trigramPostings[token.substring(offset, offset + 3)];
        if (postings == null) return const <Map<String, dynamic>>[];
        if (candidates == null || postings.length < candidates.length) {
          candidates = postings;
        }
      }
    }

    final result = <Map<String, dynamic>>[];
    if (candidates == null) {
      for (final entry in _entries) {
        if (tokens.every(entry.searchable.contains)) result.add(entry.host);
      }
      return result;
    }
    for (final index in candidates) {
      final entry = _entries[index];
      if (tokens.every(entry.searchable.contains)) result.add(entry.host);
    }
    return result;
  }
}

class _SearchEntry {
  _SearchEntry(this.host) : searchable = _searchableText(host);

  final Map<String, dynamic> host;
  final String searchable;

  static String _searchableText(Map<String, dynamic> host) {
    final tags = host['tags'];
    final searchable = <String>[
      host['hostname']?.toString() ?? '',
      host['username']?.toString() ?? '',
      host['user_name']?.toString() ?? '',
      host['current_user']?.toString() ?? '',
      host['owner_username']?.toString() ?? '',
      host['ip']?.toString() ?? '',
      host['local_ip']?.toString() ?? '',
      host['remote_ip']?.toString() ?? '',
      host['public_ip']?.toString() ?? '',
      if (host['local_ips'] is List)
        ...(host['local_ips'] as List).map((ip) => ip.toString()),
      host['department']?.toString() ?? '',
      host['ad_ou']?.toString() ?? '',
      host['group_name']?.toString() ?? '',
      host['os_family']?.toString() ?? '',
      host['os_version']?.toString() ?? '',
      host['agent_version']?.toString() ?? '',
      host['fingerprint']?.toString() ?? '',
      if (tags is List) ...tags.map((tag) => tag.toString()),
    ].join(' ').toLowerCase();
    return searchable;
  }
}

/// Case-insensitive AND search helper retained for callers and unit tests.
List<Map<String, dynamic>> searchLinkHosts(
    List<Map<String, dynamic>> hosts, String query) {
  return LinkHostSearchIndex(hosts).search(query);
}

/// Formats raw LDAP DN or OU path into clean hierarchical path:
/// "OU=Администраторы,OU=IT-отдел,DC=corp,DC=local" -> "IT-отдел / Администраторы"
String formatOU(String raw) {
  final s = raw.trim();
  if (s.isEmpty) return '';
  if (!s.toUpperCase().contains('OU=')) {
    return s;
  }
  final parts = s.split(',');
  final ous = <String>[];
  for (final p in parts) {
    final trimmed = p.trim();
    if (trimmed.toUpperCase().startsWith('OU=')) {
      final name = trimmed.substring(3).trim();
      if (name.isNotEmpty) {
        ous.add(name);
      }
    }
  }
  if (ous.isEmpty) {
    return s;
  }
  return ous.reversed.join(' / ');
}

class LinkCatalogScreen extends StatefulWidget {
  const LinkCatalogScreen({super.key});

  @override
  State<LinkCatalogScreen> createState() => _LinkCatalogScreenState();
}

enum _CatalogRowType { ou, group, host }

class _CatalogRow {
  const _CatalogRow({
    required this.type,
    this.key = '',
    this.label = '',
    this.target = '',
    this.memberCount = 0,
    this.onlineCount = 0,
    this.expanded = false,
    this.host,
  });

  final _CatalogRowType type;
  final String key;
  final String label;
  final String target;
  final int memberCount;
  final int onlineCount;
  final bool expanded;
  final Map<String, dynamic>? host;
}

class _LinkCatalogScreenState extends State<LinkCatalogScreen>
    with WidgetsBindingObserver {
  final TextEditingController _search = TextEditingController();
  Timer? _presenceTimer;
  String _query = '';
  bool _bindingThisHost = false;
  List<Map<String, dynamic>>? _indexedHosts;
  LinkHostSearchIndex? _searchIndex;
  final Map<String, bool> _expansionOverrides = {};

  Future<T> _traceAction<T>(String operation, Future<T> Function() action,
      {String? agentId, String? state}) async {
    final watch = Stopwatch()..start();
    final fields = <String, Object?>{'operation': operation,
      'request_id': DebugLogService.instance.nextRequestId(),
      if (agentId != null) 'agent_id': agentId, if (state != null) 'state': state};
    DebugLogService.instance.record('ui.catalog.action.started', fields: fields);
    try {
      final result = await action();
      DebugLogService.instance.record('ui.catalog.action.completed', fields: {
        ...fields, 'result': 'await_returned', 'duration_ms': watch.elapsedMilliseconds,
      });
      return result;
    } catch (error) {
      DebugLogService.instance.record('ui.catalog.action.failed', error: error,
          fields: {...fields, 'duration_ms': watch.elapsedMilliseconds});
      rethrow;
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<AuthState>().loadLinkHosts();
      _startPresenceRefresh();
    });
  }

  void _startPresenceRefresh() {
    _presenceTimer?.cancel();
    _presenceTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (mounted &&
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
        context.read<AuthState>().loadLinkHosts();
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (mounted) context.read<AuthState>().loadLinkHosts();
      _startPresenceRefresh();
    } else {
      _presenceTimer?.cancel();
      _presenceTimer = null;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _presenceTimer?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _bindThisHost(AuthState auth, bool isRu) async {
    DebugLogService.instance.record('ui.catalog.bind.intent');
    if (_bindingThisHost || auth.api == null) {
      DebugLogService.instance.record('ui.catalog.bind.blocked', fields: {'reason': _bindingThisHost ? 'busy' : 'no_api'});
      return;
    }
    setState(() => _bindingThisHost = true);
    try {
      final credential = await _traceAction('enrollment_credential', () => auth.api!.createLinkEnrollmentCredential());
      if (!mounted) return;
      if (!credential.expiresAt.isAfter(DateTime.now().toUtc())) {
        throw StateError('Link enrollment credential expired before binding');
      }
      final serverUrl = auth.serverUrl;
      if (serverUrl == null || serverUrl.trim().isEmpty) {
        throw StateError('No active Link server is configured');
      }
      await _traceAction('bind_local_agent', () => LinkAgentBindingService().bindHost(
        serverUrl: serverUrl,
        enrollmentToken: credential.token,
      ));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(isRu
            ? 'Этот компьютер привязан к вашей учётной записи.'
            : 'This computer is linked to your account.'),
      ));
      await auth.loadLinkHosts();
    } catch (error) {
      DebugLogService.instance.record('ui.catalog.bind.failed', error: error);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(linkAgentBindingErrorMessage(error, isRu: isRu)),
      ));
    } finally {
      if (mounted) setState(() => _bindingThisHost = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthState>();
    final isRu = auth.isRu;
    bool isExternal = false;
    String? clientIp;
    try {
      isExternal = auth.isExternalPerimeter;
      clientIp = auth.clientIp;
    } catch (error) { DebugLogService.instance.record('ui.catalog.context.failed', error: error); }
    if (!identical(_indexedHosts, auth.linkHosts) ||
        _searchIndex?.length != auth.linkHosts.length) {
      _indexedHosts = auth.linkHosts;
      _searchIndex = LinkHostSearchIndex(auth.linkHosts);
    }
    final hosts = _searchIndex!.search(_query);
    final folders = <String, Map<String, List<Map<String, dynamic>>>>{};
    final ouRawTargets = <String, String>{};
    for (final host in hosts) {
      final rawOU = host['ad_ou']?.toString().trim() ?? '';
      final formattedOU = formatOU(rawOU);
      final ou = formattedOU.isNotEmpty
          ? formattedOU
          : (isRu ? 'Без подразделения' : 'Unassigned OU');
      if (rawOU.isNotEmpty) {
        final existing = ouRawTargets[ou];
        if (existing == null || (!existing.contains('OU=') && rawOU.contains('OU='))) {
          ouRawTargets[ou] = rawOU;
        }
      }
      final group = (host['group_name']?.toString().trim().isNotEmpty ?? false)
          ? host['group_name'].toString().trim()
          : (isRu ? 'Без группы' : 'Unassigned group');
      folders.putIfAbsent(ou, () => {}).putIfAbsent(group, () => []).add(host);
    }
    final ouNames = folders.keys.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

    return NeuralMeshBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          shape: const Border(
            bottom: BorderSide(color: Color(0x1AFFFFFF), width: 1),
          ),
          title: Text(isRu ? 'Ligament Link' : 'Ligament Link'),
          actions: [
            if (Platform.isWindows || Platform.isMacOS || Platform.isLinux)
              FilledButton.tonalIcon(
                onPressed: _bindingThisHost || !auth.linkFeatureAvailable
                    ? null
                    : () => _bindThisHost(auth, isRu),
                label: Text(isRu ? 'Добавить ПК' : 'Add computer'),
                icon: _bindingThisHost
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.add_to_queue_rounded),
              ),
            IconButton(
              tooltip: isRu ? 'Обновить каталог' : 'Refresh catalog',
              onPressed: auth.linkHostsLoading ? null : () => _traceAction('refresh_cycle', auth.loadLinkHosts),
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
        body: Column(
          children: [
            // Live Perimeter Awareness (внутренний / внешний периметр)
            if (clientIp != null || isExternal)
              Container(
                margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: isExternal
                      ? const Color(0xFF451A03)
                      : const Color(0xFF064E3B),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: isExternal
                        ? const Color(0xFFD97706)
                        : const Color(0xFF059669),
                    width: 1,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      isExternal
                          ? Icons.cloud_outlined
                          : Icons.verified_user_outlined,
                      size: 18,
                      color: isExternal
                          ? const Color(0xFFF59E0B)
                          : const Color(0xFF34D399),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        isExternal
                            ? (isRu
                                ? 'Внешний периметр (${clientIp ?? "внешний IP"}) · Подключение требует Step-Up 2FA'
                                : 'External perimeter (${clientIp ?? "public IP"}) · Step-Up 2FA required')
                            : (isRu
                                ? 'Корпоративная сеть (${clientIp ?? "внутренний IP"}) · Доверенный периметр'
                                : 'Corporate network (${clientIp ?? "internal IP"}) · Trusted perimeter'),
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: isExternal
                              ? const Color(0xFFFDE68A)
                              : const Color(0xFFA7F3D0),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: TextField(
                controller: _search,
                onChanged: (value) {
                  DebugLogService.instance.record('ui.catalog.search.changed');
                  setState(() => _query = value);
                },
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: isRu
                      ? 'Имя, пользователь, OU, ОС или тег'
                      : 'Name, user, OU, OS or tag',
                  prefixIcon: const Icon(Icons.search, color: Color(0xFF38BDF8)),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          tooltip: isRu ? 'Очистить' : 'Clear',
                          onPressed: () {
                            DebugLogService.instance.record('ui.catalog.search.clear');
                            _search.clear();
                            setState(() => _query = '');
                          },
                          icon: const Icon(Icons.close),
                        ),
                  filled: true,
                  fillColor: const Color(0xFF131B2B).withValues(alpha: 0.85),
                  border:
                      OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),
            if (auth.linkHostsLoading)
              const LinearProgressIndicator(minHeight: 2),
            if (auth.linkHostsError != null && auth.linkHosts.isNotEmpty)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  isRu
                      ? 'Не удалось обновить каталог. Доступность ПК неизвестна.'
                      : 'Inventory refresh failed. PC availability is unknown.',
                  style: const TextStyle(color: Colors.amber),
                ),
              ),
            Expanded(
                child: _buildBody(
                    auth, ouNames, folders, ouRawTargets, hosts, isRu)),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(
    AuthState auth,
    List<String> ouNames,
    Map<String, Map<String, List<Map<String, dynamic>>>> folders,
    Map<String, String> ouRawTargets,
    List<Map<String, dynamic>> hosts,
    bool isRu,
  ) {
    if (!auth.linkFeatureAvailable) {
      return _message(
        isRu
            ? 'Функция Link не включена в лицензии сервера.'
            : 'Link is not enabled by the server license.',
        Icons.lock_outline,
      );
    }
    if (auth.linkHostsError != null && auth.linkHosts.isEmpty) {
      return _message(
        '${isRu ? 'Не удалось загрузить каталог' : 'Could not load inventory'}\n${auth.linkHostsError}',
        Icons.cloud_off_outlined,
      );
    }
    if (auth.linkHostsLoading && auth.linkHosts.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (hosts.isEmpty) {
      return _message(
        _query.isNotEmpty
            ? (isRu ? 'Совпадений нет' : 'No matches')
            : (isRu
                ? 'Зачисленных компьютеров пока нет.'
                : 'No enrolled computers yet.'),
        Icons.desktop_windows_outlined,
      );
    }

    final rows = _visibleCatalogRows(ouNames, folders, ouRawTargets);
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
          sliver: SliverList.builder(
            itemCount: rows.length,
            itemBuilder: (context, index) {
              final row = rows[index];
              return switch (row.type) {
                _CatalogRowType.ou => _folderRow(
                    label: row.label,
                    subtitle: isRu
                        ? '${row.onlineCount} онлайн · ${row.memberCount} компьютеров'
                        : '${row.onlineCount} online · ${row.memberCount} computers',
                    expanded: row.expanded,
                    onTap: () => _toggleExpansion(row.key),
                    isOU: true,
                    isRu: isRu,
                    onManageAccess: auth.isLinkAdmin && row.target.isNotEmpty
                        ? () => _showGroupAccessDialog(
                              type: 'ou',
                              target: row.target,
                              label: row.label,
                              isRu: isRu,
                              auth: auth,
                            )
                        : null,
                  ),
                _CatalogRowType.group => _folderRow(
                    label: row.label,
                    subtitle: isRu ? '${row.memberCount} ПК' : '${row.memberCount} PCs',
                    expanded: row.expanded,
                    onTap: () => _toggleExpansion(row.key),
                    isOU: false,
                    isRu: isRu,
                    onManageAccess: null,
                  ),
                _CatalogRowType.host => Padding(
                    padding: const EdgeInsets.only(left: 32),
                    child: _hostRow(row.host!, isRu, auth),
                  ),
              };
            },
          ),
        ),
      ],
    );
  }

  List<_CatalogRow> _visibleCatalogRows(
    List<String> ouNames,
    Map<String, Map<String, List<Map<String, dynamic>>>> folders,
    Map<String, String> ouRawTargets,
  ) {
    final rows = <_CatalogRow>[];
    for (final ou in ouNames) {
      final groups = folders[ou]!;
      final members = groups.values.expand((group) => group);
      final key = 'ou\u0000$ou';
      final expanded = _isExpanded(key);
      final rawTarget = ouRawTargets[ou] ?? '';
      rows.add(_CatalogRow(
        type: _CatalogRowType.ou,
        key: key,
        label: ou,
        target: rawTarget,
        memberCount:
            groups.values.fold<int>(0, (sum, group) => sum + group.length),
        onlineCount: members.where((host) => host['is_online'] == true).length,
        expanded: expanded,
      ));
      if (!expanded) continue;

      final groupNames = groups.keys.toList()
        ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      for (final groupName in groupNames) {
        final groupKey = 'group\u0000$ou\u0000$groupName';
        final groupExpanded = _isExpanded(groupKey);
        rows.add(_CatalogRow(
          type: _CatalogRowType.group,
          key: groupKey,
          label: groupName,
          target: groupName,
          memberCount: groups[groupName]!.length,
          expanded: groupExpanded,
        ));
        if (groupExpanded) {
          for (final host in groups[groupName]!) {
            rows.add(_CatalogRow(type: _CatalogRowType.host, host: host));
          }
        }
      }
    }
    return rows;
  }

  bool _isExpanded(String key) => _expansionOverrides[key] ?? _query.isNotEmpty;

  void _toggleExpansion(String key) {
    DebugLogService.instance.record('ui.catalog.folder.toggle', fields: {'state': _isExpanded(key) ? 'collapse' : 'expand'});
    setState(() => _expansionOverrides[key] = !_isExpanded(key));
  }

  Widget _folderRow({
    required String label,
    required bool expanded,
    required VoidCallback onTap,
    required bool isOU,
    String? subtitle,
    VoidCallback? onManageAccess,
    bool isRu = true,
  }) {
    return Card(
      color: isOU
          ? const Color(0xFF131B2B).withValues(alpha: 0.88)
          : const Color(0xFF0F1725).withValues(alpha: 0.82),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: isOU ? const Color(0x2238BDF8) : const Color(0x14FFFFFF),
          width: 1,
        ),
      ),
      margin: EdgeInsets.only(left: isOU ? 0 : 16, top: 3, bottom: 3),
      child: ListTile(
        dense: !isOU,
        minTileHeight: isOU ? 64 : 46,
        contentPadding: EdgeInsets.symmetric(horizontal: isOU ? 12 : 10),
        onTap: onTap,
        leading: Icon(
          isOU ? Icons.folder_outlined : Icons.folder_open_outlined,
          color: isOU ? const Color(0xFF38BDF8) : const Color(0xFF64748B),
          size: isOU ? 22 : 18,
        ),
        title: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: isOU ? Colors.white : const Color(0xFFCBD5E1),
            fontSize: isOU ? 14 : 12,
          ),
        ),
        subtitle: subtitle == null
            ? null
            : Text(subtitle,
                style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 11)),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (onManageAccess != null)
              IconButton(
                key: ValueKey('folder-access-$label'),
                tooltip: isRu ? 'Доступ операторов' : 'Operator access',
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints.tightFor(width: 32, height: 32),
                padding: EdgeInsets.zero,
                icon: const Icon(Icons.manage_accounts_outlined,
                    size: 20, color: Color(0xFF38BDF8)),
                onPressed: onManageAccess,
              ),
            Icon(
              expanded ? Icons.expand_less : Icons.expand_more,
              color: const Color(0xFF94A3B8),
            ),
          ],
        ),
      ),
    );
  }

  static String formatOS(dynamic osFamily, dynamic osVersion) {
    final family = (osFamily?.toString() ?? '').trim();
    final version = (osVersion?.toString() ?? '').trim();
    if (version.isEmpty) return family;
    if (family.isEmpty) return version;
    if (version.toLowerCase().startsWith(family.toLowerCase())) return version;
    return '$family $version';
  }

  Widget _hostRow(Map<String, dynamic> host, bool isRu, AuthState auth) {
    final online = host['is_online'] == true;
    final unknown = host['is_online'] == null;
    final hostname = host['hostname']?.toString().trim();
    final os = formatOS(host['os_family'], host['os_version']);
    final status = host['status']?.toString() ?? 'enrolled';
    final localIPs = host['local_ips'];
    String? firstIpv4;
    if (localIPs is List) {
      for (final item in localIPs) {
        final s = item.toString().trim();
        if (s.contains('.') && !s.contains(':')) {
          firstIpv4 = s;
          break;
        }
      }
    }
    final isUnattended = host['unattended_enabled'] == true;
    final canManage = host['can_manage_access'] == true || auth.isLinkAdmin;
    final currentUserId = _getCurrentUserId(auth);
    final isOwner = currentUserId.isNotEmpty &&
        host['owner_user_id']?.toString() == currentUserId;
    final isConsoleAllowed = host['console_allowed'] == true;

    final ownerDisplayName = (host['owner_display_name'] ?? '').toString().trim();
    final ownerUsername = (host['owner_username'] ?? '').toString().trim();
    final ownerPosition = (host['owner_position'] ?? '').toString().trim();
    final interactiveUser = (host['interactive_username'] ?? '').toString().trim();

    final effectiveName = ownerDisplayName.isNotEmpty
        ? ownerDisplayName
        : (ownerUsername.isNotEmpty
            ? ownerUsername
            : (interactiveUser.isNotEmpty ? interactiveUser : ''));
    final effectiveLogin = ownerUsername.isNotEmpty
        ? ownerUsername
        : (ownerDisplayName.isEmpty && interactiveUser.isNotEmpty ? '' : interactiveUser);
    final effectivePosition = ownerPosition.isNotEmpty
        ? ownerPosition
        : (host['ad_ou'] != null && host['ad_ou'].toString().trim().isNotEmpty
            ? host['ad_ou'].toString().trim()
            : '');

    // Определяем иконку ОС
    final isMac = os.toLowerCase().contains('mac') || os.toLowerCase().contains('darwin');
    final isLinux = os.toLowerCase().contains('linux');
    final deviceIcon = isMac
        ? Icons.laptop_mac
        : (isLinux ? Icons.terminal : Icons.desktop_windows);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A).withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: const Color(0xFF334155).withValues(alpha: 0.5),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
            // Иконка устройства со статусом
            Stack(
              alignment: Alignment.bottomRight,
              children: [
                Tooltip(
                  message: isMac ? 'macOS' : (isLinux ? 'Linux' : 'Windows'),
                  child: Container(
                    padding: const EdgeInsets.all(7),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E293B),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      deviceIcon,
                      size: 20,
                      color: online ? const Color(0xFF38BDF8) : const Color(0xFF94A3B8),
                    ),
                  ),
                ),
                Tooltip(
                  message: unknown
                      ? (isRu ? 'Неизвестно' : 'Unknown')
                      : status == 'revoked'
                          ? (isRu ? 'Отозван' : 'Revoked')
                          : status == 'suspended'
                              ? (isRu ? 'Приостановлен' : 'Suspended')
                              : online
                                  ? (isRu ? 'В сети' : 'Online')
                                  : (isRu ? 'Не в сети' : 'Offline'),
                  child: Container(
                    width: 9,
                    height: 9,
                    decoration: BoxDecoration(
                      color: online ? const Color(0xFF22C55E) : const Color(0xFF64748B),
                      shape: BoxShape.circle,
                      border: Border.all(color: const Color(0xFF0F172A), width: 1.5),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(width: 12),

            // Основная информация о хосте
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 1-я строка: Имя ПК + значок «Мой ПК»
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          hostname == null || hostname.isEmpty ? '—' : hostname,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (isOwner) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: const Color(0xFF0284C7).withValues(alpha: 0.25),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(
                              color: const Color(0xFF38BDF8).withValues(alpha: 0.5),
                            ),
                          ),
                          child: Text(
                            isRu ? 'Мой ПК' : 'My PC',
                            style: const TextStyle(
                              color: Color(0xFF38BDF8),
                              fontSize: 9.5,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                      if (isConsoleAllowed) ...[
                        const SizedBox(width: 5),
                        Tooltip(
                          message: isRu ? 'Доступна консоль Winlogon' : 'Winlogon Console available',
                          child: const Icon(Icons.terminal, size: 13, color: Color(0xFF38BDF8)),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),

                  // 2-я строка: Сотрудник / пользователь + логин
                  if (effectiveName.isNotEmpty || effectiveLogin.isNotEmpty) ...[
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            effectiveName.isNotEmpty ? effectiveName : effectiveLogin,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: effectiveName.isNotEmpty
                                  ? const Color(0xFFE2E8F0)
                                  : const Color(0xFF94A3B8),
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                        if (effectiveLogin.isNotEmpty && effectiveLogin != effectiveName) ...[
                          const SizedBox(width: 4),
                          Text(
                            '($effectiveLogin)',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Color(0xFF94A3B8),
                              fontSize: 10,
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 1),
                  ],

                  // 3-я строка: IP • Должность / OU
                  Text(
                    [
                      if (firstIpv4 != null && firstIpv4.isNotEmpty)
                        firstIpv4
                      else if (host['public_ip'] != null && host['public_ip'].toString().isNotEmpty)
                        host['public_ip'].toString(),
                      if (effectivePosition.isNotEmpty) effectivePosition,
                    ].where((s) => s.isNotEmpty).join(' • '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xFF94A3B8),
                      fontSize: 10,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),

            // Действия: статус + кнопка подключения + меню опций
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Статус В сети / Не в сети
                Text(
                  unknown
                      ? (isRu ? 'Неизвестно' : 'Unknown')
                      : status == 'revoked'
                          ? (isRu ? 'Отозван' : 'Revoked')
                          : status == 'suspended'
                              ? (isRu ? 'Приостановлен' : 'Suspended')
                              : online
                                  ? (isRu ? 'В сети' : 'Online')
                                  : (isRu ? 'Не в сети' : 'Offline'),
                  style: TextStyle(
                    color: online ? const Color(0xFF4ADE80) : const Color(0xFF94A3B8),
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),

                // Кнопка подключения
                const SizedBox(width: 10),
                OutlinedButton.icon(
                  onPressed: online ? () => _startLinkSession(host, isRu) : null,
                  icon: const Icon(Icons.play_arrow_rounded, size: 16),
                  label: Text(
                    isRu ? 'Подключить' : 'Connect',
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: online ? const Color(0xFF38BDF8) : const Color(0xFF94A3B8),
                    side: BorderSide(
                      color: online
                          ? const Color(0xFF0284C7).withValues(alpha: 0.6)
                          : const Color(0xFF334155),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
                    minimumSize: const Size(0, 32),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                  ),
                ),

                const SizedBox(width: 4),

                // Кнопка вызова дополнительных опций (Сведения, Режим доступа, Удалить)
                IconButton(
                  tooltip: isRu ? 'Опции' : 'Options',
                  icon: const Icon(Icons.more_vert, size: 18, color: Color(0xFF94A3B8)),
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints.tightFor(width: 32, height: 32),
                  padding: EdgeInsets.zero,
                  onPressed: () => _showHostOptions(host, isRu, isUnattended, canManage),
                ),
              ],
            ),
          ],
        ),
      );
  }

  void _showHostOptions(
      Map<String, dynamic> host, bool isRu, bool isUnattended, bool canManage) {
    DebugLogService.instance.record('ui.catalog.host_options.open', fields: {'agent_id': host['id']});
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1E293B),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (host['is_online'] == true)
                ListTile(
                  leading: const Icon(Icons.play_arrow_rounded, color: Color(0xFF38BDF8)),
                  title: Text(isRu ? 'Подключиться к ПК' : 'Connect to computer',
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                  onTap: () {
                    Navigator.pop(ctx);
                    _startLinkSession(host, isRu);
                  },
                ),
              ListTile(
                leading: const Icon(Icons.info_outline, color: Color(0xFF38BDF8)),
                title: Text(isRu ? 'Сведения о ПК' : 'Computer details',
                    style: const TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(ctx);
                  _showHostDetails(host, isRu);
                },
              ),
              if (canManage)
                ListTile(
                  leading: Icon(
                    isUnattended ? Icons.shield : Icons.shield_outlined,
                    color: isUnattended ? const Color(0xFF22C55E) : const Color(0xFF94A3B8),
                  ),
                  title: Text(
                    isUnattended
                        ? (isRu ? 'Выключить Unattended доступ' : 'Disable Unattended access')
                        : (isRu ? 'Включить Unattended доступ' : 'Enable Unattended access'),
                    style: const TextStyle(color: Colors.white),
                  ),
                  onTap: () {
                    Navigator.pop(ctx);
                    _toggleUnattended(host, !isUnattended, isRu);
                  },
                ),
              if (host['can_archive'] == true || host['can_unlink'] == true)
                ListTile(
                  leading: const Icon(Icons.delete_outline, color: Color(0xFFEF4444)),
                  title: Text(isRu ? 'Удалить из LINK' : 'Remove from LINK',
                      style: const TextStyle(color: Color(0xFFEF4444))),
                  onTap: () {
                    Navigator.pop(ctx);
                    _archiveHost(host, isRu);
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _toggleUnattended(
      Map<String, dynamic> host, bool enabled, bool isRu) async {
    final agentId = host['id']?.toString();
    DebugLogService.instance.record('ui.catalog.unattended.intent', fields: {'agent_id': agentId, 'state': enabled ? 'enable' : 'disable'});
    if (agentId == null || agentId.isEmpty) {
      DebugLogService.instance.record('ui.catalog.unattended.blocked', fields: {'reason': 'missing_agent'});
      return;
    }
    final auth = context.read<AuthState>();
    final api = auth.api;
    if (api == null) {
      DebugLogService.instance.record('ui.catalog.unattended.blocked', fields: {'reason': 'no_api'});
      return;
    }
    setState(() {
      host['unattended_enabled'] = enabled;
    });
    try {
      await _traceAction('unattended', () => api.updateLinkHost(agentId, unattendedEnabled: enabled), agentId: agentId, state: enabled ? 'enable' : 'disable');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(enabled
            ? (isRu
                ? 'Неконтролируемый доступ включён для ${host['hostname'] ?? agentId}'
                : 'Unattended access enabled for ${host['hostname'] ?? agentId}')
            : (isRu
                ? 'Неконтролируемый доступ выключен (требуется подтверждение кодом)'
                : 'Unattended access disabled (requires consent code)')),
        duration: const Duration(seconds: 2),
      ));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        host['unattended_enabled'] = !enabled;
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(isRu
            ? 'Не удалось изменить настройки доступа: $e'
            : 'Could not update access settings: $e'),
      ));
    }
  }

  Future<void> _archiveHost(Map<String, dynamic> host, bool isRu) async {
    final agentId = host['id'];
    if (agentId is! String || agentId.isEmpty) return;
    final auth = context.read<AuthState>();
    final api = auth.api;
    if (api == null) return;
    DebugLogService.instance.record('ui.catalog.archive.intent', fields: {'agent_id': agentId});
    var reason = '';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(isRu ? 'Удалить ПК из LINK?' : 'Remove PC from LINK?'),
        content: SizedBox(
          width: 420,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(isRu
                ? 'Компьютер «${host['hostname'] ?? agentId}» будет удалён из каталога LINK, а активные подключения завершены.\n\n⚠️ Это действие относится ТОЛЬКО к удалённому доступу LINK и НЕ влияет на двухфакторную аутентификацию Windows Logon (вход в систему).\n\nДля повторного подключения через LINK потребуется зарегистрировать ПК заново.'
                : 'Computer "${host['hostname'] ?? agentId}" will be removed from LINK catalog, and active connections will end.\n\n⚠️ This action applies ONLY to LINK remote access and DOES NOT affect Windows Logon (2FA credentials).\n\nRe-enrolling the agent will be required to connect via LINK again.'),
            const SizedBox(height: 16),
            TextField(
              onChanged: (value) => reason = value.trim(),
              maxLength: 256,
              decoration: InputDecoration(
                  labelText:
                      isRu ? 'Причина (необязательно)' : 'Reason (optional)'),
            ),
          ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(isRu ? 'Отмена' : 'Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(isRu ? 'Подтвердить' : 'Confirm')),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      DebugLogService.instance.record('ui.catalog.archive.cancelled', fields: {'agent_id': agentId, 'reason': !mounted ? 'unmounted' : 'dismissed'});
      return;
    }
    try {
      await _traceAction('archive', () => api.archiveLinkHost(agentId, reason: reason), agentId: agentId);
      await auth.loadLinkHosts();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(isRu
              ? 'ПК удалён из LINK. История сохранена.'
              : 'PC removed from LINK. History preserved.')));
    } catch (error) {
      DebugLogService.instance.record('ui.catalog.archive.failed', error: error, fields: {'agent_id': agentId});
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(isRu
              ? 'Не удалось удалить ПК. Проверьте права и обновите список; регистрация не очищалась локально.'
              : 'Could not remove PC. Check permissions and refresh the list; local enrollment was not cleared.')));
    }
  }

  Future<void> _showHostDetails(Map<String, dynamic> host, bool isRu) async {
    final watch = Stopwatch()..start();
    DebugLogService.instance.record('ui.catalog.host_details.open', fields: {'agent_id': host['id']});
    final online = host['is_online'] == true;
    final unknown = host['is_online'] == null;
    final status = host['status']?.toString() ?? 'enrolled';
    final os = formatOS(host['os_family'], host['os_version']);
    final isMac = os.toLowerCase().contains('mac') || os.toLowerCase().contains('darwin');
    final isLinux = os.toLowerCase().contains('linux');
    final deviceIcon = isMac
        ? Icons.laptop_mac
        : (isLinux ? Icons.terminal : Icons.desktop_windows);

    final localIPs = host['local_ips'];
    final notDetected = isRu ? 'Не определено' : 'Not detected';
    final hwModel = host['capabilities'] is Map
        ? host['capabilities']['hw_model']?.toString()
        : null;
    final uptimeSec = host['uptime_seconds'] is num
        ? (host['uptime_seconds'] as num).toInt()
        : 0;
    final cpuPercent = host['cpu_usage_percent'] is num
        ? (host['cpu_usage_percent'] as num).toInt()
        : 0;
    final ramUsed =
        host['ram_used_mb'] is num ? (host['ram_used_mb'] as num).toInt() : 0;
    final ramTotal =
        host['ram_total_mb'] is num ? (host['ram_total_mb'] as num).toInt() : 0;

    String formatUptime(int sec) {
      if (sec <= 0) return notDetected;
      final d = sec ~/ 86400;
      final h = (sec % 86400) ~/ 3600;
      final m = (sec % 3600) ~/ 60;
      if (d > 0) return isRu ? '$d д $h ч $m мин' : '${d}d ${h}h ${m}m';
      if (h > 0) return isRu ? '$h ч $m мин' : '${h}h ${m}m';
      return isRu ? '$m мин' : '${m}m';
    }

    final ipv4List = <String>[];
    final ipv6List = <String>[];
    if (localIPs is List) {
      for (final item in localIPs) {
        final s = item.toString().trim();
        if (s.contains('.') && !s.contains(':')) {
          ipv4List.add(s);
        } else if (s.contains(':')) {
          ipv6List.add(s);
        }
      }
    }

    final ownerText = [
      if (host['owner_display_name'] != null &&
          host['owner_display_name'].toString().trim().isNotEmpty)
        host['owner_display_name'].toString().trim(),
      if (host['owner_username'] != null &&
          host['owner_username'].toString().trim().isNotEmpty)
        '(${host['owner_username'].toString().trim()})',
      if (host['owner_position'] != null &&
          host['owner_position'].toString().trim().isNotEmpty)
        '— ${host['owner_position'].toString().trim()}',
    ].where((s) => s.isNotEmpty).join(' ').trim();

    final groupSourceText = switch (host['group_source']) {
      'explicit' => isRu ? 'Назначена явно' : 'Explicit assignment',
      'owner_group' => isRu ? 'Группа владельца' : 'Owner group',
      'owner_ldap_group' => isRu ? 'LDAP-группа владельца' : 'Owner LDAP group',
      _ => notDetected,
    };

    final unattendedText = host['unattended_enabled'] == true
        ? (isRu ? '🛡 Разрешён администратором (вход без кода)' : '🛡 Enabled (direct connect without code)')
        : (isRu ? '🔒 Выключен (требуется согласие на хосте)' : '🔒 Disabled (requires consent on host)');

    Widget detailItem(
      String label,
      String value, {
      bool copiable = false,
    }) {
      final isDetected = value.isNotEmpty && value != notDetected;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 150,
              child: Text(
                label,
                style: const TextStyle(
                  color: Color(0xFF94A3B8),
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            Expanded(
              child: SelectableText(
                value.isNotEmpty ? value : notDetected,
                style: TextStyle(
                  color: isDetected ? Colors.white : const Color(0xFF64748B),
                  fontSize: 12,
                  fontWeight: isDetected ? FontWeight.w500 : FontWeight.normal,
                ),
              ),
            ),
            if (copiable && isDetected) ...[
              const SizedBox(width: 4),
              IconButton(
                tooltip: isRu ? 'Копировать' : 'Copy',
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints.tightFor(width: 24, height: 24),
                padding: EdgeInsets.zero,
                icon: const Icon(Icons.copy_rounded, size: 14, color: Color(0xFF94A3B8)),
                onPressed: () {
                  DebugLogService.instance.record('ui.catalog.host_details.copy', fields: {'agent_id': host['id'], 'result': 'dispatched'});
                  Clipboard.setData(ClipboardData(text: value));
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    duration: const Duration(seconds: 1),
                    content: Text(isRu ? 'Скопировано в буфер: $value' : 'Copied: $value'),
                  ));
                },
              ),
            ],
          ],
        ),
      );
    }

    Widget detailSection(String title, List<Widget> items) {
      if (items.isEmpty) return const SizedBox.shrink();
      return Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFF0F172A).withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFF334155).withValues(alpha: 0.35)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                color: Color(0xFF38BDF8),
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.2,
              ),
            ),
            const SizedBox(height: 8),
            ...items,
          ],
        ),
      );
    }

    final scrollController = ScrollController();
    await showDialog<void>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: const Color(0xFF131B2B),
        titlePadding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        title: Row(
          children: [
            Icon(deviceIcon, size: 20, color: online ? const Color(0xFF38BDF8) : const Color(0xFF94A3B8)),
            const SizedBox(width: 8),
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      host['hostname']?.toString() ?? (isRu ? 'Компьютер' : 'Computer'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Colors.white),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: online ? const Color(0xFF22C55E) : const Color(0xFF64748B),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 5),
                  Text(
                    unknown
                        ? (isRu ? 'Неизвестно' : 'Unknown')
                        : status == 'revoked'
                            ? (isRu ? 'Отозван' : 'Revoked')
                            : status == 'suspended'
                                ? (isRu ? 'Приостановлен' : 'Suspended')
                                : online
                                    ? (isRu ? 'В сети' : 'Online')
                                    : (isRu ? 'Не в сети' : 'Offline'),
                    style: TextStyle(
                      color: online ? const Color(0xFF4ADE80) : const Color(0xFF94A3B8),
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
            if (online) ...[
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: () {
                  Navigator.pop(dialogCtx);
                  _startLinkSession(host, isRu);
                },
                icon: const Icon(Icons.play_arrow_rounded, size: 15),
                label: Text(isRu ? 'Подключить' : 'Connect'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF38BDF8),
                  side: const BorderSide(color: Color(0xFF0284C7)),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 0),
                  minimumSize: const Size(0, 30),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                ),
              ),
            ],
            const SizedBox(width: 4),
            IconButton(
              tooltip: isRu ? 'Закрыть' : 'Close',
              icon: const Icon(Icons.close, size: 18, color: Color(0xFF94A3B8)),
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 32, height: 32),
              onPressed: () => Navigator.pop(dialogCtx),
            ),
          ],
        ),
        content: SizedBox(
          width: 520,
          height: 480,
          child: Scrollbar(
            thumbVisibility: true,
            controller: scrollController,
            child: SingleChildScrollView(
              controller: scrollController,
              padding: const EdgeInsets.only(right: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  detailSection(
                    isRu ? 'Система и оборудование' : 'System & Hardware',
                    [
                      detailItem(isRu ? 'Имя компьютера' : 'Hostname', host['hostname']?.toString() ?? notDetected, copiable: true),
                      detailItem(isRu ? 'ОС и версия' : 'OS and version', formatOS(host['os_family'], host['os_version'])),
                      detailItem(isRu ? 'Модель ПК' : 'Hardware model', (hwModel != null && hwModel.isNotEmpty) ? hwModel : notDetected),
                      if (uptimeSec > 0)
                        detailItem(isRu ? 'Время работы' : 'Uptime', formatUptime(uptimeSec)),
                      if (cpuPercent > 0)
                        detailItem(isRu ? 'Загрузка ЦП' : 'CPU load', '$cpuPercent%'),
                      if (ramTotal > 0)
                        detailItem(isRu ? 'Оперативная память' : 'RAM usage', '$ramUsed МБ / $ramTotal МБ'),
                    ],
                  ),
                  detailSection(
                    isRu ? 'Сеть и адреса' : 'Network & Addresses',
                    [
                      detailItem(isRu ? 'Локальный IP (IPv4)' : 'Local IP (IPv4)', ipv4List.isNotEmpty ? ipv4List.join(', ') : notDetected, copiable: ipv4List.isNotEmpty),
                      if (ipv6List.isNotEmpty)
                        detailItem(isRu ? 'IPv6 адреса' : 'IPv6 addresses', ipv6List.join(', '), copiable: true),
                      detailItem(isRu ? 'Внешний IP' : 'External IP', (host['public_ip'] != null && host['public_ip'].toString().isNotEmpty) ? host['public_ip'].toString() : notDetected, copiable: host['public_ip'] != null),
                    ],
                  ),
                  detailSection(
                    isRu ? 'Пользователь и доступ' : 'User & Access',
                    [
                      detailItem(isRu ? 'Владелец' : 'Owner', ownerText.isNotEmpty ? ownerText : notDetected),
                      detailItem(isRu ? 'Пользователь за ПК' : 'Signed-in user', (host['interactive_username'] != null && host['interactive_username'].toString().isNotEmpty) ? host['interactive_username'].toString() : notDetected),
                      detailItem(isRu ? 'Группа' : 'Group', (host['group_name'] != null && host['group_name'].toString().isNotEmpty) ? host['group_name'].toString() : notDetected),
                      detailItem(isRu ? 'Источник группы' : 'Group source', groupSourceText),
                      detailItem(isRu ? 'Неконтролируемый доступ' : 'Unattended access', unattendedText),
                    ],
                  ),
                  detailSection(
                    isRu ? 'Параметры агента' : 'Agent Parameters',
                    [
                      detailItem(isRu ? 'Версия агента' : 'Agent version', (host['agent_version'] != null && host['agent_version'].toString().isNotEmpty) ? host['agent_version'].toString() : notDetected),
                      detailItem(isRu ? 'Отпечаток ключа' : 'Fingerprint', host['fingerprint']?.toString() ?? notDetected, copiable: host['fingerprint'] != null),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: Text(isRu ? 'Закрыть' : 'Close'),
          ),
        ],
      ),
    );
    DebugLogService.instance.record('ui.catalog.host_details.closed', fields: {'agent_id': host['id'], 'duration_ms': watch.elapsedMilliseconds});
  }

  String _getCurrentUserId(AuthState auth) {
    try {
      return auth.currentUser?['id']?.toString() ?? '';
    } catch (_) {
      return '';
    }
  }

  Future<void> _startLinkSession(Map<String, dynamic> host, bool isRu) async {
    final watch = Stopwatch()..start();
    final agentId = host['id']?.toString();
    DebugLogService.instance.record('ui.catalog.connect.intent', fields: {'agent_id': agentId});
    if (agentId == null || agentId.isEmpty) {
      DebugLogService.instance.record('ui.catalog.connect.blocked', fields: {'reason': 'missing_agent'});
      return;
    }

    final isConsoleAllowed = host['console_allowed'] == true;
    final consoleProfile = host['console_profile']?.toString() ?? 'work';
    final interactiveUser = (host['interactive_username'] ?? '').toString().trim();

    String? mode = 'control';
    String sessionKind = 'link';

    if (isConsoleAllowed) {
      if (interactiveUser.isEmpty) {
        // ПК заблокирован или на экране входа — подключаемся к системной консоли Winlogon
        sessionKind = 'console';
        if (consoleProfile == 'view') mode = 'view';
      } else {
        // На ПК есть активный сеанс пользователя — предлагаем выбор
        final chosen = await showDialog<String>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            backgroundColor: const Color(0xFF131B2B),
            title: Text(isRu ? 'Режим подключения к ПК' : 'Connection mode'),
            content: Text(isRu
                ? 'На компьютере работает $interactiveUser.\nКуда вы хотите подключиться?'
                : 'User $interactiveUser is active.\nWhere would you like to connect?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, 'link'),
                child: Text(isRu ? '💻 К рабочему столу' : '💻 User desktop'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, 'console'),
                child: Text(isRu ? '🖥️ В консоль Winlogon' : '🖥️ Winlogon Console'),
              ),
            ],
          ),
        );
        if (chosen == null || !mounted) {
          DebugLogService.instance.record('ui.catalog.connect.cancelled', fields: {'agent_id': agentId, 'duration_ms': watch.elapsedMilliseconds});
          return;
        }
        DebugLogService.instance.record('ui.catalog.connect.mode', fields: {'agent_id': agentId, 'state': chosen});
        sessionKind = chosen;
        if (sessionKind == 'console' && consoleProfile == 'view') {
          mode = 'view';
        }
      }
    } else {
      sessionKind = 'link';
    }

    final currentUserId = _getCurrentUserId(context.read<AuthState>());
    final isOwner = currentUserId.isNotEmpty &&
        host['owner_user_id']?.toString() == currentUserId;

    DebugLogService.instance.record('ui.catalog.connect.dispatched', fields: {
      'agent_id': agentId, 'phase': sessionKind, 'owner': isOwner,
      'operation': mode, 'elapsed_ms': watch.elapsedMilliseconds,
    });
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => SupportOperatorScreen(
          sessionId: 'link_$agentId',
          isLink: true,
          linkAgentId: agentId,
          linkAccessMode: mode,
          ownerMode: isOwner,
          sessionData: {
            ...host,
            'id': 'link_$agentId',
            'agent_id': agentId,
            'hostname': host['hostname']?.toString() ?? agentId,
            'employee_name': host['hostname']?.toString() ?? agentId,
            'access_mode': mode,
            'is_link': true,
            'session_kind': sessionKind,
          },
        ),
      ),
    );
    DebugLogService.instance.record('ui.catalog.connect.screen_closed', fields: {'agent_id': agentId, 'duration_ms': watch.elapsedMilliseconds});
  }

  Future<void> _showGroupAccessDialog({
    required String type,
    required String target,
    required String label,
    required bool isRu,
    required AuthState auth,
  }) async {
    final api = auth.api;
    if (api == null) return;
    DebugLogService.instance.record('ui.catalog.group_access.open', fields: {'phase': type});

    await showDialog<void>(
      context: context,
      builder: (ctx) => _GroupAccessDialog(
        api: api,
        type: type,
        target: target,
        label: label,
        isRu: isRu,
      ),
    );
  }

  Widget _message(String text, IconData icon) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: const Color(0xFF64748B), size: 36),
              const SizedBox(height: 12),
              Text(text,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Color(0xFF94A3B8))),
            ],
          ),
        ),
      );
}

class _GroupAccessDialog extends StatefulWidget {
  const _GroupAccessDialog({
    required this.api,
    required this.type,
    required this.target,
    required this.label,
    required this.isRu,
  });

  final dynamic api;
  final String type;
  final String target;
  final String label;
  final bool isRu;

  @override
  State<_GroupAccessDialog> createState() => _GroupAccessDialogState();
}

class _GroupOperatorItem {
  _GroupOperatorItem({
    required this.operatorUserId,
    required this.username,
    required this.displayName,
    required this.email,
    required this.hasAccess,
    required this.allowUnattended,
  });

  final String operatorUserId;
  final String username;
  final String displayName;
  final String email;
  bool hasAccess;
  bool allowUnattended;
}

class _GroupAccessDialogState extends State<_GroupAccessDialog> {
  bool _loading = true;
  bool _saving = false;
  String? _error;
  List<_GroupOperatorItem> _operators = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final watch = Stopwatch()..start();
    DebugLogService.instance.record('ui.catalog.group_access.load.started', fields: {'phase': widget.type});
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await widget.api.getLinkGroupAccess(
        type: widget.type,
        target: widget.target,
      );
      final rawOps = res['operators'] as List<dynamic>? ?? [];
      final ops = <_GroupOperatorItem>[];
      for (final raw in rawOps) {
        if (raw is Map<String, dynamic>) {
          ops.add(_GroupOperatorItem(
            operatorUserId: raw['operator_user_id']?.toString() ?? '',
            username: raw['username']?.toString() ?? '',
            displayName: raw['display_name']?.toString() ?? '',
            email: raw['email']?.toString() ?? '',
            hasAccess: raw['has_access'] == true,
            allowUnattended: raw['allow_unattended'] == true,
          ));
        }
      }
      DebugLogService.instance.record('ui.catalog.group_access.load.completed', fields: {'count': ops.length, 'duration_ms': watch.elapsedMilliseconds});
      if (mounted) {
        setState(() {
          _operators = ops;
          _loading = false;
        });
      }
    } catch (e) {
      DebugLogService.instance.record('ui.catalog.group_access.load.failed', error: e, fields: {'duration_ms': watch.elapsedMilliseconds});
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  Future<void> _save() async {
    final watch = Stopwatch()..start();
    DebugLogService.instance.record('ui.catalog.group_access.save.started', fields: {'phase': widget.type, 'count': _operators.length});
    setState(() => _saving = true);
    try {
      final rules = _operators
          .map((op) => {
                'operator_user_id': op.operatorUserId,
                'has_access': op.hasAccess,
                'allow_unattended': op.allowUnattended,
              })
          .toList();
      await widget.api.updateLinkGroupAccess(
        type: widget.type,
        target: widget.target,
        rules: rules,
      );
      DebugLogService.instance.record('ui.catalog.group_access.save.completed', fields: {'count': rules.length, 'duration_ms': watch.elapsedMilliseconds});
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(widget.isRu
            ? 'Права доступа к группе сохранены.'
            : 'Group access rights updated.'),
      ));
    } catch (e) {
      DebugLogService.instance.record('ui.catalog.group_access.save.failed', error: e, fields: {'duration_ms': watch.elapsedMilliseconds});
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content:
              Text('${widget.isRu ? "Ошибка сохранения" : "Save error"}: $e'),
          backgroundColor: Colors.red.shade800,
        ));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isRu = widget.isRu;
    return Dialog(
      backgroundColor: const Color(0xFF0F172A),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 540, maxHeight: 600),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: const Color(0xFF0284C7).withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.manage_accounts_outlined,
                        color: Color(0xFF38BDF8), size: 24),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          widget.type == 'ou'
                              ? (widget.target.isNotEmpty &&
                                      widget.target != widget.label
                                  ? widget.target
                                  : (isRu
                                      ? 'Подразделение (OU) Active Directory'
                                      : 'Active Directory OU'))
                              : (isRu
                                  ? 'Группа компьютеров'
                                  : 'Computer group'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Color(0xFF94A3B8), fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, color: Color(0xFF94A3B8)),
                  ),
                ],
              ),
              const Divider(color: Color(0xFF1E293B), height: 24),
              Text(
                isRu
                    ? 'Назначьте операторов, которым разрешено подключение к ПК этой группы:'
                    : 'Assign operators allowed to connect to PCs in this group:',
                style: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 12),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: _buildContent(isRu),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed:
                        _saving ? null : () {
                          DebugLogService.instance.record('ui.catalog.group_access.cancelled');
                          Navigator.of(context).pop();
                        },
                    child: Text(isRu ? 'Отмена' : 'Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: _loading || _saving ? null : _save,
                    icon: _saving
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.check, size: 18),
                    label: Text(isRu ? 'Сохранить' : 'Save'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildContent(bool isRu) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: Colors.amber, size: 32),
            const SizedBox(height: 8),
            Text(_error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.amber, fontSize: 12)),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: _load,
              icon: const Icon(Icons.refresh, size: 16),
              label: Text(isRu ? 'Повторить' : 'Retry'),
            ),
          ],
        ),
      );
    }
    if (_operators.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.person_off_outlined,
                  color: Color(0xFF64748B), size: 36),
              const SizedBox(height: 8),
              Text(
                isRu
                    ? 'В системе нет активных операторов Link.\nНазначьте роль «Оператор Ligament Link» в настройках пользователей.'
                    : 'No Link operators found.\nAssign "Link Operator" role in User Management.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.separated(
      itemCount: _operators.length,
      separatorBuilder: (_, __) =>
          const Divider(color: Color(0xFF1E293B), height: 1),
      itemBuilder: (context, index) {
        final op = _operators[index];
        final name = op.displayName.isNotEmpty ? op.displayName : op.username;
        return ListTile(
          dense: true,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          leading: CircleAvatar(
            backgroundColor: const Color(0xFF1E293B),
            child: Text(
              name.isNotEmpty ? name[0].toUpperCase() : '?',
              style: const TextStyle(
                  color: Color(0xFF38BDF8), fontWeight: FontWeight.bold),
            ),
          ),
          title: Text(
            name,
            style: const TextStyle(
                color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            op.email.isNotEmpty ? op.email : '@${op.username}',
            style: const TextStyle(color: Color(0xFF64748B), fontSize: 11),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Tooltip(
                message: isRu
                    ? (op.allowUnattended
                        ? 'Неконтролируемый доступ (без кода подтверждения) разрешён'
                        : 'Нажмите для включения неконтролируемого доступа')
                    : (op.allowUnattended
                        ? 'Unattended access allowed'
                        : 'Click to enable unattended access'),
                child: IconButton(
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints.tightFor(width: 32, height: 32),
                  onPressed: op.hasAccess
                      ? () {
                          DebugLogService.instance.record('ui.catalog.group_access.unattended.toggle', fields: {'state': op.allowUnattended ? 'disable' : 'enable', 'code': index});
                          setState(() => op.allowUnattended = !op.allowUnattended);
                        }
                      : null,
                  icon: Icon(
                    op.allowUnattended ? Icons.shield : Icons.shield_outlined,
                    color: op.hasAccess
                        ? (op.allowUnattended
                            ? const Color(0xFF22C55E)
                            : const Color(0xFF64748B))
                        : const Color(0xFF334155),
                    size: 18,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Tooltip(
                message: isRu
                    ? (op.hasAccess ? 'Доступ разрешён' : 'Доступ запрещён')
                    : (op.hasAccess ? 'Access granted' : 'Access denied'),
                child: Switch(
                  value: op.hasAccess,
                  activeThumbColor: const Color(0xFF38BDF8),
                  activeTrackColor: const Color(0xFF0284C7),
                  onChanged: (val) {
                    DebugLogService.instance.record('ui.catalog.group_access.permission.toggle', fields: {'state': val ? 'allow' : 'deny', 'code': index});
                    setState(() {
                      op.hasAccess = val;
                      if (!val) op.allowUnattended = false;
                    });
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
