import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'support_operator_screen.dart';
import '../services/auth_state.dart';
import '../services/link_agent_binding_service.dart';

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
    this.memberCount = 0,
    this.onlineCount = 0,
    this.expanded = false,
    this.host,
  });

  final _CatalogRowType type;
  final String key;
  final String label;
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
    if (_bindingThisHost || auth.api == null) return;
    setState(() => _bindingThisHost = true);
    try {
      final credential = await auth.api!.createLinkEnrollmentCredential();
      if (!mounted) return;
      if (!credential.expiresAt.isAfter(DateTime.now().toUtc())) {
        throw StateError('Link enrollment credential expired before binding');
      }
      final serverUrl = auth.serverUrl;
      if (serverUrl == null || serverUrl.trim().isEmpty) {
        throw StateError('No active Link server is configured');
      }
      await LinkAgentBindingService().bindHost(
        serverUrl: serverUrl,
        enrollmentToken: credential.token,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(isRu
            ? 'Этот компьютер привязан к вашей учётной записи.'
            : 'This computer is linked to your account.'),
      ));
      await auth.loadLinkHosts();
    } catch (error) {
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
    if (!identical(_indexedHosts, auth.linkHosts) ||
        _searchIndex?.length != auth.linkHosts.length) {
      _indexedHosts = auth.linkHosts;
      _searchIndex = LinkHostSearchIndex(auth.linkHosts);
    }
    final hosts = _searchIndex!.search(_query);
    final folders = <String, Map<String, List<Map<String, dynamic>>>>{};
    for (final host in hosts) {
      final ou = (host['ad_ou']?.toString().trim().isNotEmpty ?? false)
          ? host['ad_ou'].toString().trim()
          : (isRu ? 'Без подразделения' : 'Unassigned OU');
      final group = (host['group_name']?.toString().trim().isNotEmpty ?? false)
          ? host['group_name'].toString().trim()
          : (isRu ? 'Без группы' : 'Unassigned group');
      folders.putIfAbsent(ou, () => {}).putIfAbsent(group, () => []).add(host);
    }
    final ouNames = folders.keys.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

    return Scaffold(
      backgroundColor: const Color(0xFF0B0F19),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0B0F19),
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
            onPressed: auth.linkHostsLoading ? null : auth.loadLinkHosts,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: TextField(
              controller: _search,
              onChanged: (value) => setState(() => _query = value),
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
                          _search.clear();
                          setState(() => _query = '');
                        },
                        icon: const Icon(Icons.close),
                      ),
                filled: true,
                fillColor: const Color(0xFF131B2B),
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
          Expanded(child: _buildBody(auth, ouNames, folders, hosts, isRu)),
        ],
      ),
    );
  }

  Widget _buildBody(
    AuthState auth,
    List<String> ouNames,
    Map<String, Map<String, List<Map<String, dynamic>>>> folders,
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

    final rows = _visibleCatalogRows(ouNames, folders);
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
                  ),
                _CatalogRowType.group => _folderRow(
                    label: row.label,
                    expanded: row.expanded,
                    onTap: () => _toggleExpansion(row.key),
                    isOU: false,
                  ),
                _CatalogRowType.host => Padding(
                    padding: const EdgeInsets.only(left: 28),
                    child: _hostRow(row.host!, isRu),
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
  ) {
    final rows = <_CatalogRow>[];
    for (final ou in ouNames) {
      final groups = folders[ou]!;
      final members = groups.values.expand((group) => group);
      final key = 'ou\u0000$ou';
      final expanded = _isExpanded(key);
      rows.add(_CatalogRow(
        type: _CatalogRowType.ou,
        key: key,
        label: ou,
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
    setState(() => _expansionOverrides[key] = !_isExpanded(key));
  }

  Widget _folderRow({
    required String label,
    required bool expanded,
    required VoidCallback onTap,
    required bool isOU,
    String? subtitle,
  }) {
    return Card(
      color: isOU ? const Color(0xFF131B2B) : const Color(0xFF0F1725),
      margin: EdgeInsets.only(left: isOU ? 0 : 14, top: 2, bottom: 2),
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
        trailing: Icon(
          expanded ? Icons.expand_less : Icons.expand_more,
          color: const Color(0xFF94A3B8),
        ),
      ),
    );
  }

  Widget _hostRow(Map<String, dynamic> host, bool isRu) {
    final online = host['is_online'] == true;
    final unknown = host['is_online'] == null;
    final hostname = host['hostname']?.toString().trim();
    final os = [host['os_family'], host['os_version']]
        .where((part) => part != null && part.toString().isNotEmpty)
        .join(' ');
    final status = host['status']?.toString() ?? 'enrolled';
    final localIPs = host['local_ips'];
    return Container(
      constraints: const BoxConstraints(minHeight: 46),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        child: Row(
          children: [
            Icon(Icons.circle,
                size: 8,
                color:
                    online ? const Color(0xFF22C55E) : const Color(0xFF64748B)),
            const SizedBox(width: 10),
            Expanded(
                flex: 3,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      hostname == null || hostname.isEmpty ? '—' : hostname,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w600),
                    ),
                    Text(
                      [
                        if (localIPs is List && localIPs.isNotEmpty)
                          localIPs.first.toString()
                        else if (host['public_ip'] != null &&
                            host['public_ip'].toString().isNotEmpty)
                          host['public_ip'].toString(),
                        if (host['interactive_username'] != null &&
                            host['interactive_username'].toString().isNotEmpty)
                          '👤 ${host['interactive_username']}',
                      ].where((s) => s.isNotEmpty).join(' • '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Color(0xFF64748B), fontSize: 10),
                    ),
                  ],
                )),
            Expanded(
                flex: 2,
                child: Text(
                  os.isEmpty ? '—' : os,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:
                      const TextStyle(color: Color(0xFF94A3B8), fontSize: 11),
                )),
            Tooltip(
              message: isRu
                  ? 'Доступность агента. Экран и управление проверяются при подключении.'
                  : 'Agent availability. Screen and control are checked when connecting.',
              child: Text(
                unknown
                    ? (isRu ? 'Неизвестно' : 'Unknown')
                    : online
                        ? (isRu ? 'Онлайн' : 'Online')
                        : status == 'revoked'
                            ? (isRu ? 'Отозван' : 'Revoked')
                            : status == 'suspended'
                                ? (isRu ? 'Приостановлен' : 'Suspended')
                                : (isRu ? 'Офлайн' : 'Offline'),
                style: TextStyle(
                    color: online
                        ? const Color(0xFF4ADE80)
                        : const Color(0xFF94A3B8),
                    fontSize: 10),
              ),
            ),
            IconButton(
              tooltip: isRu ? 'Сведения о компьютере' : 'Computer details',
              onPressed: () => _showHostDetails(host, isRu),
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints.tightFor(width: 32, height: 34),
              padding: EdgeInsets.zero,
              icon: const Icon(Icons.info_outline, size: 16),
            ),
            if (host['can_archive'] == true || host['can_unlink'] == true)
              IconButton(
                tooltip: host['can_archive'] == true
                    ? (isRu ? 'Удалить из LINK' : 'Remove from LINK')
                    : (isRu ? 'Отвязать мой ПК' : 'Unlink my PC'),
                onPressed: () => _archiveHost(host, isRu),
                visualDensity: VisualDensity.compact,
                constraints:
                    const BoxConstraints.tightFor(width: 32, height: 34),
                padding: EdgeInsets.zero,
                icon: const Icon(Icons.link_off, size: 16),
              ),
            IconButton(
              tooltip: isRu ? 'Подключиться' : 'Connect',
              onPressed: online ? () => _startLinkSession(host, isRu) : null,
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints.tightFor(width: 34, height: 34),
              padding: EdgeInsets.zero,
              icon: const Icon(Icons.desktop_windows_outlined, size: 16),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _archiveHost(Map<String, dynamic> host, bool isRu) async {
    final agentId = host['id'];
    if (agentId is! String || agentId.isEmpty) return;
    final auth = context.read<AuthState>();
    final api = auth.api;
    if (api == null) return;
    var reason = '';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(host['can_archive'] == true
            ? (isRu ? 'Удалить ПК из LINK?' : 'Remove PC from LINK?')
            : (isRu ? 'Отвязать мой ПК?' : 'Unlink my PC?')),
        content: SizedBox(
          width: 420,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(isRu
                ? '${host['hostname'] ?? agentId}: доступ и текущие подключения будут прекращены. История сохранится. Для добавления заново потребуется регистрация агента.'
                : '${host['hostname'] ?? agentId}: access and current connections will end. History is preserved. Adding this PC again requires agent enrollment.'),
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
    if (confirmed != true || !mounted) return;
    try {
      await api.archiveLinkHost(agentId, reason: reason);
      await auth.loadLinkHosts();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(isRu
              ? 'ПК удалён из LINK. История сохранена.'
              : 'PC removed from LINK. History preserved.')));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(isRu
              ? 'Не удалось удалить ПК. Проверьте права и обновите список; регистрация не очищалась локально.'
              : 'Could not remove PC. Check permissions and refresh the list; local enrollment was not cleared.')));
    }
  }

  Future<void> _showHostDetails(Map<String, dynamic> host, bool isRu) async {
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

    final values = <(String, String)>[
      (
        isRu ? 'Имя компьютера' : 'Hostname',
        host['hostname']?.toString() ?? notDetected,
      ),
      (
        isRu ? 'Владелец' : 'Owner',
        (host['owner_username'] != null &&
                host['owner_username'].toString().isNotEmpty)
            ? host['owner_username'].toString()
            : notDetected,
      ),
      (
        isRu ? 'Пользователь за ПК' : 'Signed-in user',
        (host['interactive_username'] != null &&
                host['interactive_username'].toString().isNotEmpty)
            ? host['interactive_username'].toString()
            : notDetected,
      ),
      (
        isRu ? 'Локальный IP (LAN)' : 'Local IP (LAN)',
        (localIPs is List && localIPs.isNotEmpty)
            ? localIPs.join(', ')
            : notDetected,
      ),
      (
        isRu ? 'Внешний IP сервера' : 'Server-observed IP',
        (host['public_ip'] != null && host['public_ip'].toString().isNotEmpty)
            ? host['public_ip'].toString()
            : notDetected,
      ),
      (
        isRu ? 'Модель ПК / Оборудование' : 'Hardware model',
        (hwModel != null && hwModel.isNotEmpty) ? hwModel : notDetected,
      ),
      (
        isRu ? 'ОС и версия' : 'OS and version',
        [host['os_family'], host['os_version']]
            .where((value) => value != null && value.toString().isNotEmpty)
            .join(' ')
            .trim(),
      ),
      if (uptimeSec > 0 || cpuPercent > 0 || ramTotal > 0) ...[
        if (uptimeSec > 0)
          (
            isRu ? 'Время работы' : 'Uptime',
            formatUptime(uptimeSec),
          ),
        if (cpuPercent > 0)
          (
            isRu ? 'Загрузка ЦП' : 'CPU load',
            '$cpuPercent%',
          ),
        if (ramTotal > 0)
          (
            isRu ? 'Оперативная память' : 'RAM usage',
            '$ramUsed МБ / $ramTotal МБ',
          ),
      ],
      (
        isRu ? 'Группа' : 'Group',
        (host['group_name'] != null && host['group_name'].toString().isNotEmpty)
            ? host['group_name'].toString()
            : notDetected,
      ),
      (
        isRu ? 'Источник группы' : 'Group source',
        switch (host['group_source']) {
          'explicit' => isRu ? 'Назначена явно' : 'Explicit assignment',
          'owner_group' => isRu ? 'Группа владельца' : 'Owner group',
          'owner_ldap_group' =>
            isRu ? 'LDAP-группа владельца' : 'Owner LDAP group',
          _ => notDetected,
        },
      ),
      (
        isRu ? 'Версия агента' : 'Agent version',
        (host['agent_version'] != null &&
                host['agent_version'].toString().isNotEmpty)
            ? host['agent_version'].toString()
            : notDetected,
      ),
      (
        isRu ? 'Отпечаток ключа' : 'Fingerprint',
        host['fingerprint']?.toString() ?? notDetected,
      ),
    ];
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF131B2B),
        title: Text(
            host['hostname']?.toString() ?? (isRu ? 'Компьютер' : 'Computer')),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final (label, value) in values) ...[
                  Text(label,
                      style: const TextStyle(
                          color: Color(0xFF94A3B8), fontSize: 12)),
                  SelectableText(value.isNotEmpty ? value : notDetected,
                      style: TextStyle(
                          color: value.isNotEmpty && value != notDetected
                              ? Colors.white
                              : const Color(0xFF64748B),
                          fontSize: 13)),
                  const SizedBox(height: 10),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(isRu ? 'Закрыть' : 'Close')),
        ],
      ),
    );
  }

  Future<void> _startLinkSession(Map<String, dynamic> host, bool isRu) async {
    final mode = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF131B2B),
        title: Text(isRu ? 'Режим подключения' : 'Connection mode'),
        content: Text(isRu
            ? 'Управление включайте только при необходимости.'
            : 'Enable control only when needed.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, 'view'),
            child: Text(isRu ? 'Только просмотр' : 'View only'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, 'control'),
            child: Text(isRu ? 'Управление' : 'Control'),
          ),
        ],
      ),
    );
    if (mode == null || !mounted) return;
    final agentId = host['id']?.toString();
    if (agentId == null || agentId.isEmpty) return;
    final auth = context.read<AuthState>();
    final isOwner = host['owner_username'] != null &&
        host['owner_username'] == auth.username;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => SupportOperatorScreen(
          sessionId: 'link_$agentId',
          isLink: true,
          linkAgentId: agentId,
          linkAccessMode: mode,
          ownerMode: isOwner,
          sessionData: {
            'id': 'link_$agentId',
            'agent_id': agentId,
            'hostname': host['hostname']?.toString() ?? agentId,
            'employee_name': host['hostname']?.toString() ?? agentId,
            'access_mode': mode,
            'is_link': true,
            ...host,
          },
        ),
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
