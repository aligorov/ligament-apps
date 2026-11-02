import 'package:flutter_test/flutter_test.dart';
import 'package:ligament_authenticator/models/link_session_policy.dart';
import 'package:ligament_authenticator/widgets/link_file_manager_dialog.dart';

void main() {
  test('view-only permits monitor selection but never remote input', () {
    const policy =
        LinkSessionPolicy(allowClipboardIn: true, allowClipboardOut: true);
    for (final type in ['screen_list', 'switch_screen']) {
      expect(policy.allows({'type': type}, allowControl: false), true);
    }
    for (final type in [
      'mouse_move',
      'mouse_down',
      'key_down',
      'hotkey',
      'clipboard_get',
      'clipboard_set',
      'block_input'
    ]) {
      expect(policy.allows({'type': type}, allowControl: false), false);
    }
  });
  test('clipboard policy fails closed for missing/malformed flags', () {
    for (final raw in [
      null,
      false,
      'true',
      {},
      {'allow_clipboard_out': 'true'}
    ]) {
      final policy = LinkSessionPolicy.fromWire(raw);
      expect(
          policy.allows({'type': 'clipboard_get'}, allowControl: true), false);
      expect(
          policy.allows({'type': 'clipboard_set', 'text': 'secret'},
              allowControl: true),
          false);
    }
  });

  test('all clipboard directions are enforced independently on host', () {
    for (final inbound in [false, true]) {
      for (final outbound in [false, true]) {
        final policy = LinkSessionPolicy.fromWire({
          'allow_clipboard_in': inbound,
          'allow_clipboard_out': outbound,
        });
        final write = {'type': 'clipboard_set', 'text': 'data'};
        const read = {'type': 'clipboard_get'};
        expect(policy.allows(write, allowControl: true), inbound);
        expect(policy.allows(read, allowControl: true), outbound);
        expect(policy.allows(write, allowControl: false), false);
        expect(policy.allows(read, allowControl: false), false);
        expect(
            policy.allows({'type': 'clipboard_set', 'text': 'x' * 65537},
                allowControl: true),
            false);
      }
    }
  });

  test('candidate envelope supports current and legacy hosts only', () {
    const candidate = {'candidate': 'candidate:1'};
    expect(linkSignalType({'type': 'candidate'}, {'candidate': candidate}),
        'candidate');
    expect(
        linkSignalType(
            {'type': 'signal'}, {'type': 'candidate', 'candidate': candidate}),
        'candidate');
    expect(linkSignalType({'type': 'signal'}, {'candidate': candidate}),
        'candidate');
    expect(linkSignalType({'type': 'session_close'}, {'candidate': candidate}),
        'session_close');
    expect(
        linkSignalType({'type': 'signal'}, {'candidate': 'invalid'}), 'signal');
    expect(linkSignalType({}, {'type': 1}), null);
  });

  test('toolbar commands text_input, video_quality, reboot, file_* follow policy',
      () {
    final policyWithFiles = LinkSessionPolicy.fromWire({
      'allow_file_transfer': true,
    });
    final policyWithoutFiles = LinkSessionPolicy.fromWire({
      'allow_file_transfer': false,
    });

    expect(
        policyWithFiles.allows({'type': 'video_quality', 'quality': 'best'},
            allowControl: false),
        isTrue);
    expect(
        policyWithFiles.allows({'type': 'text_input', 'text': 'hello'},
            allowControl: true),
        isTrue);
    expect(
        policyWithFiles.allows({'type': 'text_input', 'text': 'hello'},
            allowControl: false),
        isFalse);
    expect(policyWithFiles.allows({'type': 'reboot'}, allowControl: true),
        isTrue);
    expect(policyWithFiles.allows({'type': 'file_start'}, allowControl: true),
        isTrue);
    expect(
        policyWithoutFiles.allows({'type': 'file_start'}, allowControl: true),
        isFalse);
    for (final fsType in [
      'fs_list',
      'fs_list_ack',
      'fs_download_start',
      'fs_delete',
      'fs_mkdir'
    ]) {
      expect(policyWithFiles.allows({'type': fsType}, allowControl: true),
          isTrue,
          reason: '$fsType should be allowed when file transfer is permitted');
      expect(policyWithoutFiles.allows({'type': fsType}, allowControl: true),
          isFalse,
          reason: '$fsType should be blocked when file transfer is disabled');
    }
  });

  test('FsEntry.fromMap parses POSIX and Windows paths correctly', () {
    final posixEntry = FsEntry.fromMap({
      'name': 'document.pdf',
      'is_dir': false,
      'size': 1048576,
      'modified': 1700000000000,
    }, '/home/user/downloads', isWindows: false);

    expect(posixEntry.name, 'document.pdf');
    expect(posixEntry.path, '/home/user/downloads/document.pdf');
    expect(posixEntry.isDir, isFalse);
    expect(posixEntry.size, 1048576);
    expect(posixEntry.modified?.millisecondsSinceEpoch, 1700000000000);

    final winEntry = FsEntry.fromMap({
      'name': 'Photos',
      'is_dir': true,
      'size': 0,
      'modified': 1700000000000,
    }, 'C:\\Users\\User', isWindows: true);

    expect(winEntry.name, 'Photos');
    expect(winEntry.path, 'C:\\Users\\User\\Photos');
    expect(winEntry.isDir, isTrue);
    expect(winEntry.size, 0);
  });
}
