#ifndef LIGAMENT_ENDPOINT_CONSOLE_HOST_PROCESS_H_
#define LIGAMENT_ENDPOINT_CONSOLE_HOST_PROCESS_H_

#include <windows.h>

#include <atomic>
#include <functional>
#include <mutex>
#include <string>
#include <thread>

// The endpoint owns this worker, independently of ordinary GUI instances.
// Secrets cross a PID-verified SYSTEM-only pipe, never a command line or file.
class ConsoleHostProcess {
 public:
  using StartResult = std::function<void(bool, const char*)>;

  ConsoleHostProcess() = default;
  ~ConsoleHostProcess();
  ConsoleHostProcess(const ConsoleHostProcess&) = delete;
  ConsoleHostProcess& operator=(const ConsoleHostProcess&) = delete;

  void Start(const std::string& session_id, const std::wstring& server_url,
             const std::string& host_token, StartResult result);
  void Stop(const std::string& session_id = {});

 private:
  void Run(const std::string& session_id, const std::wstring& server_url,
           const std::string& host_token, const StartResult& result);

  std::mutex mutex_;
  std::thread worker_;
  HANDLE stop_ = nullptr;
  std::atomic<bool> running_{false};
  std::string session_id_;
};

#endif  // LIGAMENT_ENDPOINT_CONSOLE_HOST_PROCESS_H_
