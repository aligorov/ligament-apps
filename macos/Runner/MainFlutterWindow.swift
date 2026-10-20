import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    let linkAgentChannel = FlutterMethodChannel(
      name: "ligament/link_agent",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    linkAgentChannel.setMethodCallHandler { call, result in
      guard call.method == "ensureMacAgentRunning" else {
        result(FlutterMethodNotImplemented)
        return
      }
      do {
        try Self.installAndStartLinkAgent()
        result(nil)
      } catch {
        let nsError = error as NSError
        let code = nsError.domain == "LigamentLinkAgent" && nsError.code == 2
          ? "link_agent_missing"
          : "link_agent_launchd_failed"
        result(FlutterError(
          code: code,
          message: "Could not install or start the per-user Link LaunchAgent",
          details: error.localizedDescription
        ))
      }
    }

    NotificationCenter.default.addObserver(self, selector: #selector(onWindowFocusOrActivation), name: NSWindow.didBecomeKeyNotification, object: self)
    NotificationCenter.default.addObserver(self, selector: #selector(onWindowFocusOrActivation), name: NSWindow.didBecomeMainNotification, object: self)
    NotificationCenter.default.addObserver(self, selector: #selector(onWindowFocusOrActivation), name: NSWindow.didDeminiaturizeNotification, object: self)
    NotificationCenter.default.addObserver(self, selector: #selector(onWindowFocusOrActivation), name: NSApplication.didBecomeActiveNotification, object: nil)

    super.awakeFromNib()
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  private static func installAndStartLinkAgent() throws {
    guard let appExecutable = Bundle.main.executableURL else {
      throw NSError(domain: "LigamentLinkAgent", code: 1, userInfo: [
        NSLocalizedDescriptionKey: "Could not resolve the app executable"
      ])
    }
    let agentURL = appExecutable.deletingLastPathComponent()
      .appendingPathComponent("link-agent", isDirectory: false)
    guard FileManager.default.isExecutableFile(atPath: agentURL.path) else {
      throw NSError(domain: "LigamentLinkAgent", code: 2, userInfo: [
        NSLocalizedDescriptionKey: "The bundled Link Agent is missing"
      ])
    }

    let homeURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    let launchAgentsURL = homeURL.appendingPathComponent(
      "Library/LaunchAgents", isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: launchAgentsURL,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let plistURL = launchAgentsURL.appendingPathComponent(
      "com.ligament.link-agent.plist", isDirectory: false
    )
    let job: [String: Any] = [
      "Label": "com.ligament.link-agent",
      "ProgramArguments": [agentURL.path],
      "RunAtLoad": true,
      "KeepAlive": true,
    ]
    let plistData = try PropertyListSerialization.data(
      fromPropertyList: job,
      format: .xml,
      options: 0
    )
    try plistData.write(to: plistURL, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: plistURL.path
    )

    let domain = "gui/\(getuid())"
    _ = try? runLaunchctl(["bootout", domain, plistURL.path])
    _ = try runLaunchctl(["bootstrap", domain, plistURL.path])
    _ = try runLaunchctl(["enable", "\(domain)/com.ligament.link-agent"])
  }

  @discardableResult
  private static func runLaunchctl(_ arguments: [String]) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = arguments
    let errorPipe = Pipe()
    process.standardError = errorPipe
    try process.run()
    process.waitUntilExit()
    let status = process.terminationStatus
    if status != 0 {
      let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
      let output = String(data: errorData, encoding: .utf8) ?? ""
      throw NSError(domain: "LigamentLinkAgent", code: Int(status), userInfo: [
        NSLocalizedDescriptionKey: output.isEmpty
          ? "launchctl failed with status \(status)"
          : output.trimmingCharacters(in: .whitespacesAndNewlines)
      ])
    }
    return status
  }

  @objc private func onWindowFocusOrActivation() {
    triggerMetalRedraw()
  }

  override func orderFront(_ sender: Any?) {
    super.orderFront(sender)
    triggerMetalRedraw()
  }

  override func makeKeyAndOrderFront(_ sender: Any?) {
    super.makeKeyAndOrderFront(sender)
    triggerMetalRedraw()
  }

  override func setIsVisible(_ flag: Bool) {
    super.setIsVisible(flag)
    if flag {
      triggerMetalRedraw()
    }
  }

  override func deminiaturize(_ sender: Any?) {
    super.deminiaturize(sender)
    triggerMetalRedraw()
  }

  private func triggerMetalRedraw() {
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      self.contentView?.needsDisplay = true
      self.contentViewController?.view.needsLayout = true
      self.contentViewController?.view.layer?.setNeedsDisplay()
      self.contentViewController?.view.displayIfNeeded()
      self.displayIfNeeded()
    }
  }
}
