#ifndef RUNNER_LINK_HOST_BRIDGE_H_
#define RUNNER_LINK_HOST_BRIDGE_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <memory>
#include <mutex>

// Session-scoped bridge to the LocalSystem Link service. It exposes only
// bounded JSON frames; authentication, WSS and identity remain in the service.
class LinkHostBridge {
 public:
  explicit LinkHostBridge(flutter::BinaryMessenger* messenger, HWND window_handle = nullptr);
  ~LinkHostBridge();
  LinkHostBridge(const LinkHostBridge&) = delete;
  LinkHostBridge& operator=(const LinkHostBridge&) = delete;

 private:
  void ClosePipe();

  HWND window_handle_ = nullptr;
  std::mutex mutex_;
  HANDLE pipe_ = INVALID_HANDLE_VALUE;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif  // RUNNER_LINK_HOST_BRIDGE_H_
