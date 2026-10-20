#ifndef RUNNER_LINK_AGENT_BINDING_BRIDGE_H_
#define RUNNER_LINK_AGENT_BINDING_BRIDGE_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <memory>
#include <atomic>

class LinkAgentBindingBridge {
 public:
  explicit LinkAgentBindingBridge(flutter::BinaryMessenger* messenger);
  ~LinkAgentBindingBridge();
  LinkAgentBindingBridge(const LinkAgentBindingBridge&) = delete;
  LinkAgentBindingBridge& operator=(const LinkAgentBindingBridge&) = delete;

 private:
  std::shared_ptr<std::atomic_bool> busy_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif  // RUNNER_LINK_AGENT_BINDING_BRIDGE_H_
