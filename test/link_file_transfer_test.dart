import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ligament_authenticator/widgets/link_file_manager_dialog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LinkFileTransferState', () {
    test('computes active, completed and failed flags correctly', () {
      const sending = LinkFileTransferState(
        id: 'tx_1',
        filename: 'test.dmg',
        totalSize: 1000,
        transferredBytes: 400,
        progress: 0.4,
        isOutgoing: true,
        status: 'sending',
      );
      expect(sending.isActive, isTrue);
      expect(sending.isCompleted, isFalse);
      expect(sending.isFailed, isFalse);

      const waitingAck = LinkFileTransferState(
        id: 'tx_1',
        filename: 'test.dmg',
        totalSize: 1000,
        transferredBytes: 1000,
        progress: 1.0,
        isOutgoing: true,
        status: 'waiting_ack',
      );
      expect(waitingAck.isActive, isTrue);

      const completed = LinkFileTransferState(
        id: 'tx_1',
        filename: 'test.dmg',
        totalSize: 1000,
        transferredBytes: 1000,
        progress: 1.0,
        isOutgoing: true,
        status: 'completed',
      );
      expect(completed.isActive, isFalse);
      expect(completed.isCompleted, isTrue);
      expect(completed.isFailed, isFalse);

      const error = LinkFileTransferState(
        id: 'tx_1',
        filename: 'test.dmg',
        totalSize: 1000,
        transferredBytes: 200,
        progress: 0.2,
        isOutgoing: true,
        status: 'error',
        errorMessage: 'Network timeout',
      );
      expect(error.isActive, isFalse);
      expect(error.isCompleted, isFalse);
      expect(error.isFailed, isTrue);
    });
  });

  group('LinkFileManagerDialog reactive progress', () {
    testWidgets('renders active transfer progress, speed, percentage and cancel button', (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final transferNotifier = ValueNotifier<LinkFileTransferState?>(
        const LinkFileTransferState(
          id: 'tx_100',
          filename: 'ZCode-3.15.3-mac-arm64.dmg',
          totalSize: 261304320, // ~249.2 MB
          transferredBytes: 130652160, // 50%
          progress: 0.5,
          isOutgoing: true,
          status: 'sending',
          speedText: '15.4 MB/s',
        ),
      );

      final fsStreamController = StreamController<Map<String, dynamic>>.broadcast();
      addTearDown(() {
        fsStreamController.close();
        transferNotifier.dispose();
      });

      bool cancelled = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LinkFileManagerDialog(
              sendDataMessage: (_) => true,
              fsStream: fsStreamController.stream,
              onUploadFile: (_, __) async {},
              onDownloadFile: (_, __) {},
              transferStateListenable: transferNotifier,
              onCancelTransfer: () {
                cancelled = true;
              },
            ),
          ),
        ),
      );
      await tester.pump();

      // Check percentage text
      expect(find.text('50.0%'), findsOneWidget);
      // Check filename and speed text
      expect(find.textContaining('ZCode-3.15.3-mac-arm64.dmg'), findsWidgets);
      expect(find.textContaining('15.4 MB/s'), findsOneWidget);
      // Check cancel button
      expect(find.text('Отмена'), findsOneWidget);

      await tester.tap(find.text('Отмена'));
      await tester.pump();
      expect(cancelled, isTrue);

      // Now update to completed state
      transferNotifier.value = const LinkFileTransferState(
        id: 'tx_100',
        filename: 'ZCode-3.15.3-mac-arm64.dmg',
        totalSize: 261304320,
        transferredBytes: 261304320,
        progress: 1.0,
        isOutgoing: true,
        status: 'completed',
      );
      await tester.pump();

      expect(find.textContaining('Файл успешно передан'), findsOneWidget);
    });
  });
}
