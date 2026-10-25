/// Host-side authorization. Missing or malformed flags deny clipboard access.
class LinkSessionPolicy {
  const LinkSessionPolicy({
    this.allowClipboardIn = false,
    this.allowClipboardOut = false,
    this.allowFileTransfer = false,
    this.desktopScope = 'interactive',
  });

  factory LinkSessionPolicy.fromWire(Object? value, {String? desktopScope}) {
    if (value is! Map) {
      return LinkSessionPolicy(
        desktopScope: desktopScope ?? 'interactive',
      );
    }
    return LinkSessionPolicy(
      allowClipboardIn: value['allow_clipboard_in'] == true,
      allowClipboardOut: value['allow_clipboard_out'] == true,
      allowFileTransfer: value['allow_file_transfer'] == true,
      desktopScope: (value['desktop_scope'] as String?) ?? desktopScope ?? 'interactive',
    );
  }

  final bool allowClipboardIn;
  final bool allowClipboardOut;
  final bool allowFileTransfer;
  final String desktopScope;
  static const maxClipboardLength = 65536;

  bool allows(Map<String, dynamic> input, {required bool allowControl}) {
    if (input['type'] == 'screen_list' ||
        input['type'] == 'switch_screen' ||
        input['type'] == 'video_quality' ||
        input['type'] == 'chat_message' ||
        input['type'] == 'chat_sync' ||
        input['type'] == 'chat_ack') {
      return true; // Screen/quality/chat is not keyboard/mouse/clipboard control.
    }
    if (!allowControl) return false;
    switch (input['type']) {
      case 'clipboard_set':
        final text = input['text'];
        return allowClipboardIn &&
            text is String &&
            text.length <= maxClipboardLength;
      case 'clipboard_get':
        return allowClipboardOut;
      case 'file_start':
      case 'file_chunk':
      case 'file_end':
        return allowFileTransfer;
      default:
        return const {
          'mouse_move',
          'mouse_down',
          'mouse_up',
          'wheel',
          'key_down',
          'key_up',
          'hotkey',
          'text_input',
          'block_input',
          'reboot',
        }.contains(input['type']);
    }
  }
}

/// Normalizes the legacy host envelope without accepting unrelated signals.
String? linkSignalType(
    Map<String, dynamic> event, Map<String, dynamic> payload) {
  final outer = event['type'];
  if (outer == 'signal') {
    final inner = payload['type'];
    if (inner is String && inner.isNotEmpty) return inner;
    if (payload['candidate'] is Map) return 'candidate';
  }
  final inner = payload['type'];
  return outer is String ? outer : (inner is String ? inner : null);
}
