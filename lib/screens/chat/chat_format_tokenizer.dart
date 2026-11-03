import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Быстрый линейный O(N) токенизатор сущностей форматирования сообщений (Telegram/Discord стиль).
/// Не создает тяжелого AST-дерева и мгновенно компилирует текст в плоский List<InlineSpan>.
class ChatFormatTokenizer {
  static final RegExp _tokenRegex = RegExp(
    r'(\*\*[^*\n]+\*\*)|(\*[^*\n]+\*)|(`[^`\n]+`)|(https?:\/\/[^\s]+)',
  );

  static List<InlineSpan> tokenize(
    String raw,
    BuildContext context, {
    void Function(String url)? onLinkTap,
  }) {
    if (raw.isEmpty) return const [];

    final theme = Theme.of(context);
    final spans = <InlineSpan>[];
    var lastMatchEnd = 0;

    for (final match in _tokenRegex.allMatches(raw)) {
      if (match.start > lastMatchEnd) {
        spans.add(TextSpan(text: raw.substring(lastMatchEnd, match.start)));
      }

      final text = match.group(0)!;
      if (text.startsWith('**') && text.endsWith('**') && text.length >= 4) {
        spans.add(TextSpan(
          text: text.substring(2, text.length - 2),
          style: const TextStyle(fontWeight: FontWeight.bold),
        ));
      } else if (text.startsWith('*') && text.endsWith('*') && text.length >= 2) {
        spans.add(TextSpan(
          text: text.substring(1, text.length - 1),
          style: const TextStyle(fontStyle: FontStyle.italic),
        ));
      } else if (text.startsWith('`') && text.endsWith('`') && text.length >= 2) {
        spans.add(WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 2),
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(
                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
              ),
            ),
            child: Text(
              text.substring(1, text.length - 1),
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12.5,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ));
      } else if (text.startsWith('http://') || text.startsWith('https://')) {
        spans.add(TextSpan(
          text: text,
          style: TextStyle(
            color: theme.colorScheme.primary,
            decoration: TextDecoration.underline,
          ),
          recognizer: TapGestureRecognizer()..onTap = () => onLinkTap?.call(text),
        ));
      }

      lastMatchEnd = match.end;
    }

    if (lastMatchEnd < raw.length) {
      spans.add(TextSpan(text: raw.substring(lastMatchEnd)));
    }

    return spans;
  }
}
