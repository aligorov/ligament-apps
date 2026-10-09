import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../i18n/app_strings.dart';
import '../services/auth_state.dart';
import '../services/rdp_actions.dart';
import '../widgets/rdp_target_tile.dart';

class AppsScreen extends StatefulWidget {
  const AppsScreen({super.key});

  @override
  State<AppsScreen> createState() => _AppsScreenState();
}

class _AppsScreenState extends State<AppsScreen> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';
  String _selectedFilter = 'all'; // all | workstations | apps

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _refresh(context.read<AuthState>());
      }
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _refresh(AuthState auth) async {
    await Future.wait([
      auth.loadAllowedApps(),
      if (auth.rdpFeatureAvailable) auth.loadRdpTargets(),
    ]);
  }

  Future<void> _launchApp(BuildContext context, String url) async {
    final s = context.stringsRead;
    final uri = Uri.tryParse(url);
    if (uri == null || (!uri.isScheme('http') && !uri.isScheme('https'))) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${s.appsSchemeBlocked}: $url')),
        );
      }
      return;
    }
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${s.appsCantOpen}: $url')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthState>();
    final s = context.strings;
    final isRu = auth.isRu;

    final allApps = auth.allowedApps;
    final allTargets = auth.rdpFeatureAvailable ? auth.rdpTargets : <Map<String, dynamic>>[];

    // Фильтрация по строке поиска
    final q = _query.trim().toLowerCase();
    final targets = q.isEmpty
        ? allTargets
        : allTargets.where((t) {
            final name = t['name']?.toString().toLowerCase() ?? '';
            final kind = t['kind']?.toString().toLowerCase() ?? '';
            return name.contains(q) || kind.contains(q);
          }).toList();

    final apps = q.isEmpty
        ? allApps
        : allApps.where((a) {
            final name = a['name']?.toString().toLowerCase() ?? '';
            return name.contains(q);
          }).toList();

    final showWorkstations = (_selectedFilter == 'all' || _selectedFilter == 'workstations') && targets.isNotEmpty;
    final showApps = (_selectedFilter == 'all' || _selectedFilter == 'apps') && apps.isNotEmpty;
    final isEmpty = !showWorkstations && !showApps;

    return Scaffold(
      backgroundColor: const Color(0xFF0B0F19),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0B0F19),
        elevation: 0,
        shape: const Border(
          bottom: BorderSide(color: Color(0x1AFFFFFF), width: 1),
        ),
        title: Text(
          isRu ? 'Сервисы и рабочие места' : 'Services & Workstations',
          style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded, color: Color(0xFF38BDF8)),
            onPressed: () => _refresh(auth),
            tooltip: s.appsRefresh,
          ),
        ],
      ),
      body: Column(
        children: [
          // Панель поиска и фильтров
          if (allTargets.isNotEmpty || allApps.isNotEmpty || q.isNotEmpty)
            Container(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              color: const Color(0xFF0B0F19),
              child: Column(
                children: [
                  // Поле мгновенного поиска
                  TextField(
                    controller: _searchController,
                    onChanged: (val) => setState(() => _query = val),
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                    decoration: InputDecoration(
                      hintText: isRu
                          ? 'Поиск рабочих мест и сервисов...'
                          : 'Search workstations & apps...',
                      hintStyle: const TextStyle(color: Color(0xFF64748B), fontSize: 13),
                      prefixIcon: const Icon(Icons.search_rounded, color: Color(0xFF38BDF8), size: 20),
                      suffixIcon: _query.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear_rounded, color: Color(0xFF94A3B8), size: 18),
                              onPressed: () {
                                _searchController.clear();
                                setState(() => _query = '');
                              },
                            )
                          : null,
                      filled: true,
                      fillColor: const Color(0xFF131B2B),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: const BorderSide(color: Color(0xFF38BDF8), width: 1.2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Сегментированные фильтр-чипы категорий
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        _filterChip(
                          label: isRu ? 'Все (${allTargets.length + allApps.length})' : 'All (${allTargets.length + allApps.length})',
                          value: 'all',
                          icon: Icons.grid_view_rounded,
                        ),
                        if (allTargets.isNotEmpty) ...[
                          const SizedBox(width: 8),
                          _filterChip(
                            label: isRu ? 'Рабочие места (${allTargets.length})' : 'Workstations (${allTargets.length})',
                            value: 'workstations',
                            icon: Icons.desktop_windows_rounded,
                          ),
                        ],
                        if (allApps.isNotEmpty) ...[
                          const SizedBox(width: 8),
                          _filterChip(
                            label: isRu ? 'Приложения (${allApps.length})' : 'Apps (${allApps.length})',
                            value: 'apps',
                            icon: Icons.shield_rounded,
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),

          // Основное скроллируемое содержимое с секциями
          Expanded(
            child: RefreshIndicator(
              onRefresh: () => _refresh(auth),
              child: isEmpty
                  ? _buildEmptyState(isRu, q.isNotEmpty)
                  : CustomScrollView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      slivers: [
                        // Секция 1: Мои рабочие места
                        if (showWorkstations) ...[
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
                              child: Row(
                                children: [
                                  const Icon(Icons.desktop_windows_outlined, color: Color(0xFF38BDF8), size: 20),
                                  const SizedBox(width: 8),
                                  Text(
                                    isRu ? 'Мои рабочие места' : 'My Workstations',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF0284C7).withValues(alpha: 0.2),
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border.all(color: const Color(0xFF0284C7).withValues(alpha: 0.4)),
                                    ),
                                    child: Text(
                                      '${targets.length}',
                                      style: const TextStyle(color: Color(0xFF38BDF8), fontSize: 11, fontWeight: FontWeight.bold),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          SliverPadding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            sliver: SliverGrid(
                              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                                maxCrossAxisExtent: 380,
                                mainAxisExtent: 168,
                                crossAxisSpacing: 12,
                                mainAxisSpacing: 12,
                              ),
                              delegate: SliverChildBuilderDelegate(
                                (context, index) {
                                  final t = targets[index];
                                  return RdpTargetTile(
                                    target: t,
                                    isRu: isRu,
                                    margin: EdgeInsets.zero,
                                    connecting: auth.rdp.isBusy,
                                    onConnect: () => RdpActions.connectRdp(context, auth, t),
                                    onScreen: RdpActions.isOwnerScreenBusy
                                        ? null
                                        : () => RdpActions.openOwnerScreen(
                                              context,
                                              auth,
                                              t,
                                              onBusyChanged: (_) {
                                                if (mounted) setState(() {});
                                              },
                                            ),
                                  );
                                },
                                childCount: targets.length,
                              ),
                            ),
                          ),
                        ],

                        // Секция 2: Корпоративные приложения (SSO)
                        if (showApps) ...[
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: EdgeInsets.fromLTRB(16, showWorkstations ? 24 : 16, 16, 12),
                              child: Row(
                                children: [
                                  const Icon(Icons.shield_rounded, color: Color(0xFF38BDF8), size: 20),
                                  const SizedBox(width: 8),
                                  Text(
                                    isRu ? 'Корпоративные приложения (SSO)' : 'Corporate Apps (SSO)',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF0284C7).withValues(alpha: 0.15),
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border.all(color: const Color(0xFF0284C7).withValues(alpha: 0.35)),
                                    ),
                                    child: Text(
                                      '${apps.length}',
                                      style: const TextStyle(color: Color(0xFF38BDF8), fontSize: 11, fontWeight: FontWeight.bold),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          SliverPadding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            sliver: SliverGrid(
                              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                                maxCrossAxisExtent: 240,
                                mainAxisExtent: 180,
                                crossAxisSpacing: 12,
                                mainAxisSpacing: 12,
                              ),
                              delegate: SliverChildBuilderDelegate(
                                (context, index) {
                                  final app = apps[index];
                                  final name = app['name']?.toString() ?? (isRu ? 'Сервис' : 'Service');
                                  final launchUrl = app['launch_url']?.toString() ?? '';
                                  final icon = _getAppIcon(name, launchUrl);
                                  final sub = _getAppSubtitle(name, launchUrl, isRu);

                                  return Container(
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF131B2B),
                                      borderRadius: BorderRadius.circular(16),
                                      border: Border.all(
                                        color: Colors.white.withValues(alpha: 0.08),
                                        width: 1,
                                      ),
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.black.withValues(alpha: 0.35),
                                          blurRadius: 14,
                                          offset: const Offset(0, 4),
                                        ),
                                      ],
                                    ),
                                    child: Material(
                                      color: Colors.transparent,
                                      child: InkWell(
                                        onTap: launchUrl.isNotEmpty ? () => _launchApp(context, launchUrl) : null,
                                        borderRadius: BorderRadius.circular(16),
                                        child: Padding(
                                          padding: const EdgeInsets.all(14),
                                          child: Column(
                                            mainAxisAlignment: MainAxisAlignment.center,
                                            children: [
                                              Container(
                                                width: 48,
                                                height: 48,
                                                decoration: BoxDecoration(
                                                  shape: BoxShape.circle,
                                                  gradient: LinearGradient(
                                                    colors: [
                                                      const Color(0xFF0284C7).withValues(alpha: 0.22),
                                                      const Color(0xFF0369A1).withValues(alpha: 0.08),
                                                    ],
                                                    begin: Alignment.topLeft,
                                                    end: Alignment.bottomRight,
                                                  ),
                                                  border: Border.all(
                                                    color: const Color(0xFF38BDF8).withValues(alpha: 0.35),
                                                    width: 1,
                                                  ),
                                                ),
                                                child: Icon(icon, size: 24, color: const Color(0xFF38BDF8)),
                                              ),
                                              const SizedBox(height: 10),
                                              Text(
                                                name,
                                                textAlign: TextAlign.center,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  fontWeight: FontWeight.w700,
                                                  fontSize: 14,
                                                  color: Colors.white,
                                                  letterSpacing: -0.2,
                                                ),
                                              ),
                                              const SizedBox(height: 2),
                                              Text(
                                                sub,
                                                textAlign: TextAlign.center,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  fontSize: 10,
                                                  color: Color(0xFF64748B),
                                                ),
                                              ),
                                              const Spacer(),
                                              Container(
                                                width: double.infinity,
                                                padding: const EdgeInsets.symmetric(vertical: 7),
                                                decoration: BoxDecoration(
                                                  color: const Color(0xFF0284C7).withValues(alpha: 0.12),
                                                  borderRadius: BorderRadius.circular(9),
                                                  border: Border.all(
                                                    color: const Color(0xFF0284C7).withValues(alpha: 0.45),
                                                    width: 1,
                                                  ),
                                                ),
                                                child: FittedBox(
                                                  fit: BoxFit.scaleDown,
                                                  child: Row(
                                                    mainAxisAlignment: MainAxisAlignment.center,
                                                    children: [
                                                      Text(
                                                        isRu ? 'Войти через SSO' : 'Open via SSO',
                                                        style: const TextStyle(
                                                          fontSize: 11,
                                                          color: Color(0xFF38BDF8),
                                                          fontWeight: FontWeight.w700,
                                                        ),
                                                      ),
                                                      const SizedBox(width: 4),
                                                      const Icon(Icons.arrow_forward_rounded, size: 12, color: Color(0xFF38BDF8)),
                                                    ],
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  );
                                },
                                childCount: apps.length,
                              ),
                            ),
                          ),
                        ],
                        const SliverToBoxAdapter(child: SizedBox(height: 24)),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }

  IconData _getAppIcon(String name, String url) {
    final lower = '$name $url'.toLowerCase();
    if (lower.contains('pass') || lower.contains('pwd') || lower.contains('vault') || lower.contains('key')) {
      return Icons.lock_outline_rounded;
    }
    if (lower.contains('wifi') || lower.contains('wi-fi') || lower.contains('net')) {
      return Icons.wifi_rounded;
    }
    if (lower.contains('mail') || lower.contains('post') || lower.contains('inbox')) {
      return Icons.mail_outline_rounded;
    }
    if (lower.contains('git') || lower.contains('repo') || lower.contains('code')) {
      return Icons.code_rounded;
    }
    return Icons.shield_outlined;
  }

  String _getAppSubtitle(String name, String url, bool isRu) {
    final lower = '$name $url'.toLowerCase();
    if (lower.contains('pass') || lower.contains('pwd') || lower.contains('vault')) {
      return isRu ? 'Корпоративные пароли' : 'Corporate Vault';
    }
    if (lower.contains('wifi') || lower.contains('wi-fi')) {
      return isRu ? 'Корпоративная сеть' : 'Corporate Wi-Fi';
    }
    return isRu ? 'SSO · Корпоративный доступ' : 'SSO Service';
  }

  Widget _filterChip({
    required String label,
    required String value,
    required IconData icon,
  }) {
    final selected = _selectedFilter == value;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => setState(() => _selectedFilter = value),
        borderRadius: BorderRadius.circular(20),
        child: Ink(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            gradient: selected
                ? const LinearGradient(
                    colors: [Color(0xFF0284C7), Color(0xFF0EA5E9)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  )
                : null,
            color: selected ? null : const Color(0xFF131B2B),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: selected ? const Color(0xFF38BDF8) : Colors.white.withValues(alpha: 0.08),
              width: 1,
            ),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: const Color(0xFF0284C7).withValues(alpha: 0.4),
                      blurRadius: 10,
                      offset: const Offset(0, 2),
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: selected ? Colors.white : const Color(0xFF94A3B8)),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: selected ? Colors.white : const Color(0xFF94A3B8),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState(bool isRu, bool isFiltered) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isFiltered ? Icons.search_off : Icons.apps_outage_outlined,
              size: 64,
              color: Colors.blueGrey.shade700,
            ),
            const SizedBox(height: 16),
            Text(
              isFiltered
                  ? (isRu ? 'Ничего не найдено' : 'No items found')
                  : (isRu ? 'Нет доступных сервисов' : 'No services available'),
              style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            Text(
              isFiltered
                  ? (isRu ? 'Попробуйте изменить поисковый запрос или фильтр' : 'Try modifying your search or filter')
                  : (isRu ? 'Обратитесь к администратору для назначения доступа' : 'Contact your administrator for access'),
              style: const TextStyle(color: Color(0xFF64748B), fontSize: 13),
              textAlign: TextAlign.center,
            ),
            if (isFiltered) ...[
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: () {
                  _searchController.clear();
                  setState(() {
                    _query = '';
                    _selectedFilter = 'all';
                  });
                },
                icon: const Icon(Icons.refresh, size: 16),
                label: Text(isRu ? 'Сбросить фильтры' : 'Reset filters'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1E293B),
                  foregroundColor: const Color(0xFF38BDF8),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
