import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    NotificationCenter.default.addObserver(self, selector: #selector(onWindowFocusOrActivation), name: NSWindow.didBecomeKeyNotification, object: self)
    NotificationCenter.default.addObserver(self, selector: #selector(onWindowFocusOrActivation), name: NSWindow.didBecomeMainNotification, object: self)
    NotificationCenter.default.addObserver(self, selector: #selector(onWindowFocusOrActivation), name: NSWindow.didDeminiaturizeNotification, object: self)
    NotificationCenter.default.addObserver(self, selector: #selector(onWindowFocusOrActivation), name: NSApplication.didBecomeActiveNotification, object: nil)

    super.awakeFromNib()
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
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
      let f = self.frame
      self.setFrame(NSRect(x: f.origin.x, y: f.origin.y, width: f.size.width, height: f.size.height + 1), display: true)
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
        guard let self = self else { return }
        self.setFrame(f, display: true)
        self.contentView?.needsDisplay = true
        self.contentViewController?.view.needsLayout = true
        self.contentViewController?.view.layer?.setNeedsDisplay()
      }
    }
  }
}
