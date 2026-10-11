#pragma once
#include <windows.h>
#include <algorithm>
#include <cmath>

// All mouse injection and blocking are performed by the same input thread.
struct Win32RemoteMouseApi {
  static UINT Send(INPUT* input) { return ::SendInput(1, input, sizeof(INPUT)); }
  static BOOL Block(BOOL blocked) { return ::BlockInput(blocked); }
  static BOOL Clip(const RECT* rect) { return ::ClipCursor(rect); }
};

template <typename Api = Win32RemoteMouseApi>
bool SendRemoteMouse(DWORD flags, DWORD data = 0, LONG dx = 0, LONG dy = 0) {
  // Best-effort release of legacy cursor confinement; never reject input if Clip fails.
  if (flags & MOUSEEVENTF_MOVE) {
    Api::Clip(nullptr);
  }
  INPUT input{};
  input.type = INPUT_MOUSE;
  input.mi.dx = dx;
  input.mi.dy = dy;
  input.mi.dwFlags = flags;
  input.mi.mouseData = data;
  return Api::Send(&input) == 1;
}

template <typename Api = Win32RemoteMouseApi>
bool SetRemoteMouseBlocked(bool desired, bool& blocked) {
  // Best-effort release of legacy cursor confinement.
  Api::Clip(nullptr);
  if (blocked == desired) return true;
  if (!Api::Block(desired ? TRUE : FALSE)) return false;
  blocked = desired;
  return true;
}

inline LONG RemoteMouseAxis(int pixel, int origin, int extent) {
  if (extent <= 1) return 0;
  return static_cast<LONG>(std::clamp(
    std::round((static_cast<double>(pixel) - origin) * 65535.0 / (extent - 1)),
    0.0, 65535.0));
}

inline DWORD RemoteMouseButton(int button, bool down) {
  const DWORD downs[] = {MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_MIDDLEDOWN, MOUSEEVENTF_RIGHTDOWN};
  const DWORD ups[] = {MOUSEEVENTF_LEFTUP, MOUSEEVENTF_MIDDLEUP, MOUSEEVENTF_RIGHTUP};
  return (down ? downs : ups)[std::clamp(button, 0, 2)];
}
