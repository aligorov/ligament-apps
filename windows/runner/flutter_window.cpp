#include "flutter_window.h"

#include <optional>
#include <flutter/standard_method_codec.h>

#include "debug_log.h"
#include "flutter/generated_plugin_registrant.h"

namespace {
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;

Value DiagnosticsState() {
  const auto state = debug_log::GetState();
  return Value(Map{{Value("enabled"), Value(state.enabled)},
                   {Value("path"), Value(state.path)}});
}

bool WriteDiagnostic(const Value* arguments) {
  const auto* fields = arguments ? std::get_if<Map>(arguments) : nullptr;
  if (!fields || fields->empty() || fields->size() > 5) return false;
  const std::string* context = nullptr;
  const std::string* event = nullptr;
  const std::string* error_type = nullptr;
  const std::string* error_code = nullptr;
  std::optional<int64_t> os_error;
  for (const auto& field : *fields) {
    const auto* name = std::get_if<std::string>(&field.first);
    if (!name) return false;
    if (*name == "os_error") {
      if (const auto* value = std::get_if<int32_t>(&field.second)) os_error = *value;
      else if (const auto* value64 = std::get_if<int64_t>(&field.second))
        os_error = *value64;
      else return false;
      continue;
    }
    const auto* text = std::get_if<std::string>(&field.second);
    if (!text) return false;
    if (*name == "event" && debug_log::ValidEvent(*text)) event = text;
    else if (*name == "error_type" && debug_log::ValidErrorType(*text))
      error_type = text;
    else if (*name == "error_code" && debug_log::ValidErrorCode(*text))
      error_code = text;
    else if (*name == "context" && debug_log::ValidContext(*text)) context = text;
    else return false;
  }
  return event && debug_log::Write(*event, error_type ? *error_type : "",
                                   error_code ? *error_code : "", os_error,
                                   context ? *context : "");
}

void HandleDiagnostics(const flutter::MethodCall<Value>& call,
                       std::unique_ptr<flutter::MethodResult<Value>> result) {
  try {
    if (call.method_name() == "getState") {
      result->Success(DiagnosticsState());
    } else if (call.method_name() == "setEnabled") {
      if (debug_log::IsWorker()) {
        result->Error("read_only", "Worker diagnostics are read-only.");
        return;
      }
      const auto* enabled = call.arguments() ?
          std::get_if<bool>(call.arguments()) : nullptr;
      if (!enabled) {
        result->Error("invalid_arguments", "Expected a boolean.");
        return;
      }
      const uint32_t error = debug_log::SetEnabled(*enabled);
      if (error != ERROR_SUCCESS) {
        result->Error("registry_write_failed", "Cannot save diagnostics setting.",
                      Value(static_cast<int64_t>(error)));
        return;
      }
      result->Success(DiagnosticsState());
    } else if (call.method_name() == "write") {
      result->Success(Value(WriteDiagnostic(call.arguments())));
    } else {
      result->NotImplemented();
    }
  } catch (...) {
    result->Error("diagnostics_failed", "Diagnostics are unavailable.");
  }
}
}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project,
                             bool service_console,
                             bool link_host_worker,
                             bool start_minimized)
    : project_(project),
      service_console_(service_console),
      link_host_worker_(link_host_worker),
      start_minimized_(start_minimized) {}

FlutterWindow::~FlutterWindow() {
  if (diagnostics_channel_) diagnostics_channel_->SetMethodCallHandler(nullptr);
}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    debug_log::Write("window.base_create.failed", {}, {}, ::GetLastError());
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  debug_log::Write("controller.init.begin");
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    debug_log::Write("controller.init.failed", {}, {}, ::GetLastError());
    return false;
  }
  debug_log::Write("controller.init.ready");
  try {
    diagnostics_channel_ = std::make_unique<flutter::MethodChannel<Value>>(
        flutter_controller_->engine()->messenger(), "com.ligament/diagnostics",
        &flutter::StandardMethodCodec::GetInstance());
    diagnostics_channel_->SetMethodCallHandler(HandleDiagnostics);
  } catch (...) {
    debug_log::Write("diagnostics.channel.failed");
  }
  debug_log::Write("plugins.register.begin");
  RegisterPlugins(flutter_controller_->engine());
  debug_log::Write("plugins.register.end");
  if (!service_console_ && !link_host_worker_) {
    debug_log::Write("link.binding.init.begin");
    link_agent_binding_bridge_ = std::make_unique<LinkAgentBindingBridge>(
        flutter_controller_->engine()->messenger());
    debug_log::Write("link.binding.init.ready");
  }
  if (service_console_) {
    debug_log::Write("service_console.bridge.init.begin");
    service_console_bridge_ = std::make_unique<ServiceConsoleBridge>(flutter_controller_->engine()->messenger());
    debug_log::Write("service_console.bridge.init.ready");
  }
  if (link_host_worker_) {
    debug_log::Write("link.host_bridge.init.begin");
    link_host_bridge_ = std::make_unique<LinkHostBridge>(flutter_controller_->engine()->messenger());
    debug_log::Write("link.host_bridge.init.ready");
  }
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    debug_log::Write("startup.first_frame");
    if (!service_console_ && !link_host_worker_ && !start_minimized_) this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (diagnostics_channel_) {
    diagnostics_channel_->SetMethodCallHandler(nullptr);
    diagnostics_channel_.reset();
  }
  link_agent_binding_bridge_.reset();
  service_console_bridge_.reset();
  link_host_bridge_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
