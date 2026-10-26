import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_version.dart';
import '../i18n/app_strings.dart';

class AppUpdateBanner extends StatelessWidget {
  const AppUpdateBanner({
    super.key,
    required this.latestVersion,
    required this.releaseUrl,
  });

  final String latestVersion;
  final String releaseUrl;

  Future<void> _openRelease() async {
    final url = Uri.tryParse(releaseUrl);
    if (url == null || (!url.isScheme('https') && !url.isScheme('http'))) {
      return;
    }
    try {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final s = context.stringsRead;
    return Material(
      color: const Color(0xFF075985),
      child: InkWell(
        onTap: _openRelease,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              const Icon(
                Icons.system_update_alt,
                size: 18,
                color: Color(0xFF7DD3FC),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${s.updateAvailablePrefix} ${formatAppVersion(latestVersion)}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                s.updateOpen,
                style: const TextStyle(
                  color: Color(0xFF7DD3FC),
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
