import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ligament_authenticator/models/chat_models.dart';
import 'package:ligament_authenticator/screens/chat/chat_format_tokenizer.dart';

void main() {
  group('ChatFormatTokenizer Unit Tests', () {
    testWidgets('parses plain text without tokens', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                final spans = ChatFormatTokenizer.tokenize(
                  'Привет, мир!',
                  context,
                );
                expect(spans.length, 1);
                expect((spans.first as TextSpan).text, 'Привет, мир!');
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
    });

    testWidgets('parses bold, italic and inline code', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                final spans = ChatFormatTokenizer.tokenize(
                  'Это **жирный**, это *курсив*, а это `код`!',
                  context,
                );

                expect(spans.length, 7);
                expect((spans[0] as TextSpan).text, 'Это ');
                expect((spans[1] as TextSpan).text, 'жирный');
                expect((spans[1] as TextSpan).style?.fontWeight, FontWeight.bold);

                expect((spans[2] as TextSpan).text, ', это ');
                expect((spans[3] as TextSpan).text, 'курсив');
                expect((spans[3] as TextSpan).style?.fontStyle, FontStyle.italic);

                expect((spans[4] as TextSpan).text, ', а это ');
                expect(spans[5] is WidgetSpan, isTrue);
                expect((spans[6] as TextSpan).text, '!');
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
    });

    testWidgets('parses URL with tap callback', (tester) async {
      String? tappedUrl;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                final spans = ChatFormatTokenizer.tokenize(
                  'Ссылка https://example.com/test для проверки',
                  context,
                  onLinkTap: (url) => tappedUrl = url,
                );

                expect(spans.length, 3);
                expect((spans[0] as TextSpan).text, 'Ссылка ');
                expect((spans[1] as TextSpan).text, 'https://example.com/test');
                expect((spans[2] as TextSpan).text, ' для проверки');
                expect(tappedUrl, isNull);
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
    });

    testWidgets('ChatMessage caches InlineSpans', (tester) async {
      final msg = ChatMessage(
        id: 1,
        chatId: 'c1',
        senderId: 'u1',
        senderName: 'User',
        clientMsgId: 'm1',
        body: 'Сообщение с **важным** текстом',
        createdAt: DateTime.now(),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                final spans1 = msg.getSpans(context);
                final spans2 = msg.getSpans(context);
                expect(identical(spans1, spans2), isTrue);
                expect(spans1.length, 3);
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
    });
  });
}
