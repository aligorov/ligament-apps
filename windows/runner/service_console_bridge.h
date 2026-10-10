#ifndef RUNNER_SERVICE_CONSOLE_BRIDGE_H_
#define RUNNER_SERVICE_CONSOLE_BRIDGE_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <memory>

// Only registered in the endpoint-owned SYSTEM helper. No GUI credentials,
// files, shell commands or clipboard are exposed through this channel.
class ServiceConsoleBridge {
 public:
  explicit ServiceConsoleBridge(flutter::BinaryMessenger* messenger);
  ~ServiceConsoleBridge();
  ServiceConsoleBridge(const ServiceConsoleBridge&) = delete;
  ServiceConsoleBridge& operator=(const ServiceConsoleBridge&) = delete;

 private:
  class InputWorker;
  std::unique_ptr<InputWorker> input_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  bool bootstrapped_ = false;
};

#endif
