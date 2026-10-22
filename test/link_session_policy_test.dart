import 'package:flutter_test/flutter_test.dart';
import 'package:ligament_authenticator/models/link_session_policy.dart';

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
}
