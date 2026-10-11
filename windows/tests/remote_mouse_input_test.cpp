#include "../runner/remote_mouse_input.h"
#include <iostream>
#include <stdexcept>
#include <vector>

struct FakeWindows {
  static inline std::vector<INPUT> sent;
  static inline bool reject_send = false, reject_block = false, reject_clip = false, confined = true;
  static UINT Send(INPUT* input) {
    sent.push_back(*input);
    return reject_send ? 0 : 1;
  }
  static BOOL Block(BOOL) { return reject_block ? FALSE : TRUE; }
  static BOOL Clip(const RECT* rect) {
    if (reject_clip) return FALSE;
    confined = rect != nullptr;
    return TRUE;
  }
};
void Check(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}
int main() {
  try {
    bool blocked = false;
    Check(SetRemoteMouseBlocked<FakeWindows>(true, blocked), "block failed");
    Check(blocked && !FakeWindows::confined, "remote mouse trapped by physical-input block");
    const DWORD base = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK;
    for (int button = 0; button < 3; ++button) {
      for (bool down : {true, false}) {
        Check(SendRemoteMouse<FakeWindows>(base | RemoteMouseButton(button, down), 0, 16384, 49152), "button rejected");
        const auto& packet = FakeWindows::sent.back();
        Check(packet.type == INPUT_MOUSE && packet.mi.dx == 16384 && packet.mi.dy == 49152, "button lost position");
        const DWORD expected[][2] = {{MOUSEEVENTF_LEFTUP, MOUSEEVENTF_LEFTDOWN}, {MOUSEEVENTF_MIDDLEUP, MOUSEEVENTF_MIDDLEDOWN}, {MOUSEEVENTF_RIGHTUP, MOUSEEVENTF_RIGHTDOWN}};
        Check(packet.mi.dwFlags == (base | expected[button][down ? 1 : 0]), "wrong button flags");
      }
    }
    Check(SendRemoteMouse<FakeWindows>(MOUSEEVENTF_WHEEL, static_cast<DWORD>(-120)), "wheel rejected");
    Check(static_cast<LONG>(FakeWindows::sent.back().mi.mouseData) == -120, "wheel sign lost");
    FakeWindows::confined = true;  // Simulate an old helper killed before cleanup.
    Check(SendRemoteMouse<FakeWindows>(base), "move rejected after upgrade");
    Check(!FakeWindows::confined, "legacy confinement survived a remote move");
    FakeWindows::reject_clip = true;
    Check(SendRemoteMouse<FakeWindows>(base), "move must not fail when ClipCursor returns FALSE");
    Check(SetRemoteMouseBlocked<FakeWindows>(true, blocked), "block must not fail when ClipCursor returns FALSE");
    FakeWindows::reject_clip = false;
    FakeWindows::reject_send = true;
    Check(!SendRemoteMouse<FakeWindows>(base), "SendInput failure hidden");
    FakeWindows::reject_block = true;
    Check(!SetRemoteMouseBlocked<FakeWindows>(false, blocked) && blocked, "failed unblock reported as success");
    FakeWindows::reject_block = false;
    Check(SetRemoteMouseBlocked<FakeWindows>(false, blocked) && !blocked, "unblock failed");
    Check(RemoteMouseAxis(-1920,-1920,3840) == 0, "negative monitor left edge");
    Check(RemoteMouseAxis(1919,-1920,3840) == 65535, "negative monitor right edge");
    Check(RemoteMouseAxis(-9999,0,1920) == 0 && RemoteMouseAxis(9999,0,1920) == 65535, "axis not clamped");
    std::cout << "Remote mouse input tests passed\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
