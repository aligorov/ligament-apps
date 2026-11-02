# Native macOS Link Worker (ScreenCaptureKit + WebRTC) Implementation Plan

> **Execution:** Follow this plan task-by-task within the user-authorized scope. If the installed environment provides an executing-plans skill, read it before use; this catalog entry does not bundle that dependency.

**Goal:** Implement a lightweight, native macOS session worker (`link-worker-darwin`) in Swift leveraging `ScreenCaptureKit` and `WebRTC.framework`, replacing the heavy 200MB Flutter GUI instance for remote desktop sessions with instant startup (<150ms), native system audio capture, and strict TCC compliance.

**Architecture:** The Go `link-agent` receives incoming remote session offers over WSS and spawns `link-worker-darwin` connected via a private Unix domain socket. The native Swift worker initializes a headless `SCStream` for display and system audio capture (zero microphone leakage), feeds `CVPixelBuffer` frames into `WebRTC.framework` with hardware VideoToolbox encoding, manages the `link-control-v1` DataChannel for synthetic `CGEventPost` input injection, and pipes keyframes directly into the session recording pipeline.

**Tech Stack:** Swift 5.9+, macOS SDK (macOS 13+ ScreenCaptureKit, CoreGraphics, VideoToolbox, CoreAudio), `WebRTC.framework` (Objective-C/Swift API), Go 1.22+ (`link_agent`), Unix domain sockets, GitHub Actions CI.

---

### Task 1: Go Agent Launcher Resolution & Hotfix Cleanup

**Files:**
- Modify: `windows/link_agent/session_worker_unix.go:80-110`
- Modify: `windows/link_agent/session_worker_unix_test.go`
- Modify: `.github/workflows/build_clients.yml:165-175`

**Step 1: Write the failing unit test for native worker discovery**

Add a test in `windows/link_agent/session_worker_unix_test.go` asserting that on macOS `resolveUnixWorkerExecutable()` preferentially detects `link-worker-darwin`, and if absent, resolves the main bundle executable `Ligament 2FA` (and never the broken `ligament_authenticator`).

```go
func TestResolveUnixWorkerExecutable_Darwin(t *testing.T) {
    if runtime.GOOS != "darwin" {
        t.Skip("darwin only")
    }
    dir := t.TempDir()
    // 1. When native helper exists, prefer it
    nativeHelper := filepath.Join(dir, "link-worker-darwin")
    if err := os.WriteFile(nativeHelper, []byte("#!/bin/sh\nexit 0\n"), 0755); err != nil {
        t.Fatal(err)
    }
    resolved := resolveUnixWorkerExecutable(filepath.Join(dir, "link-agent"))
    if resolved != nativeHelper {
        t.Fatalf("expected native helper %q, got %q", nativeHelper, resolved)
    }

    // 2. Fallback to main app bundle binary "Ligament 2FA"
    _ = os.Remove(nativeHelper)
    mainApp := filepath.Join(dir, "Ligament 2FA")
    if err := os.WriteFile(mainApp, []byte("#!/bin/sh\nexit 0\n"), 0755); err != nil {
        t.Fatal(err)
    }
    resolvedFallback := resolveUnixWorkerExecutable(filepath.Join(dir, "link-agent"))
    if resolvedFallback != mainApp {
        t.Fatalf("expected bundle binary %q, got %q", mainApp, resolvedFallback)
    }
}
```

**Step 2: Run test to verify it fails**

Run: `(cd windows/link_agent && go test -v -run TestResolveUnixWorkerExecutable_Darwin .)`  
Expected: FAIL (`undefined: resolveUnixWorkerExecutable`).

**Step 3: Implement worker resolution in Go**

In `windows/link_agent/session_worker_unix.go`:
```go
func resolveUnixWorkerExecutable(agentPath string) string {
    dir := filepath.Dir(agentPath)
    if runtime.GOOS == "darwin" {
        // Priority 1: Dedicated native Swift helper next to agent or in Helpers
        candidates := []string{
            filepath.Join(dir, "link-worker-darwin"),
            filepath.Join(dir, "..", "Helpers", "link-worker-darwin"),
            filepath.Join(dir, "Ligament 2FA"),
        }
        for _, c := range candidates {
            if info, err := os.Stat(c); err == nil && !info.IsDir() && info.Mode()&0111 != 0 {
                return c
            }
        }
        return filepath.Join(dir, "Ligament 2FA")
    }
    return filepath.Join(dir, "ligament_authenticator")
}
```
Update `Launch()` to use `resolveUnixWorkerExecutable(executable)`.

In `.github/workflows/build_clients.yml`:
Delete the redundant line:
```bash
install -m 755 'build/macos/Build/Products/Release/Ligament 2FA.app/Contents/MacOS/Ligament 2FA' 'build/macos/Build/Products/Release/Ligament 2FA.app/Contents/MacOS/ligament_authenticator'
```

**Step 4: Run tests to verify they pass**

Run: `(cd windows/link_agent && go test ./... && go vet ./...)`  
Expected: PASS.

**Step 5: Commit**

```bash
git commit -am "fix(link-agent): resolve native macos worker and remove binary duplicate in CI"
```

---

### Task 2: Native Swift Worker IPC Framing & Protocol Models

**Files:**
- Create: `macos/link_worker/Package.swift`
- Create: `macos/link_worker/Sources/LinkWorker/Models.swift`
- Create: `macos/link_worker/Sources/LinkWorker/IPCClient.swift`
- Create: `macos/link_worker/Tests/LinkWorkerTests/IPCTests.swift`

**Step 1: Define Swift Package and Models**

Create `macos/link_worker/Package.swift`:
```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LinkWorker",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "link-worker-darwin", targets: ["LinkWorker"])
    ],
    targets: [
        .executableTarget(
            name: "LinkWorker",
            dependencies: [],
            path: "Sources/LinkWorker",
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("AVFoundation")
            ]
        ),
        .testTarget(
            name: "LinkWorkerTests",
            dependencies: ["LinkWorker"],
            path: "Tests/LinkWorkerTests"
        )
    ]
)
```

In `macos/link_worker/Sources/LinkWorker/Models.swift`:
```swift
import Foundation

public struct SessionOffer: Codable {
    public let type: String
    public let sessionId: String
    public let offerSdp: String
    public let iceServers: [[String: AnyCodable]]
    public let accessMode: String
    public let accessType: String
    public let operatorName: String?
    public let confirmationDigits: Int?
    public let recording: RecordingConfig?

    enum CodingKeys: String, CodingKey {
        case type
        case sessionId = "session_id"
        case offerSdp = "offer_sdp"
        case iceServers = "ice_servers"
        case accessMode = "access_mode"
        case accessType = "access_type"
        case operatorName = "operator_name"
        case confirmationDigits = "confirmation_digits"
        case recording
    }
}

public struct SessionAnswer: Codable {
    public let type: String = "session_answer"
    public let sessionId: String
    public let accepted: Bool
    public let sdp: String?
    public let reason: String?

    enum CodingKeys: String, CodingKey {
        case type
        case sessionId = "session_id"
        case accepted
        case sdp
        case reason
    }
}

public struct AnyCodable: Codable {
    public let value: Any
    public init(_ value: Any) { self.value = value }
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let b = try? container.decode(Bool.self) { value = b }
        else if let i = try? container.decode(Int.self) { value = i }
        else if let d = try? container.decode(Double.self) { value = d }
        else if let s = try? container.decode(String.self) { value = s }
        else if let a = try? container.decode([AnyCodable].self) { value = a.map { $0.value } }
        else if let m = try? container.decode([String: AnyCodable].self) { value = m.mapValues { $0.value } }
        else { value = "" }
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let b = value as? Bool { try container.encode(b) }
        else if let i = value as? Int { try container.encode(i) }
        else if let d = value as? Double { try container.encode(d) }
        else if let s = value as? String { try container.encode(s) }
        else { try container.encode(String(describing: value)) }
    }
}

public struct RecordingConfig: Codable {
    public let enabled: Bool?
    public let ingestUrl: String?
    public let ingestToken: String?
    enum CodingKeys: String, CodingKey {
        case enabled
        case ingestUrl = "ingest_url"
        case ingestToken = "ingest_token"
    }
}
```

In `macos/link_worker/Sources/LinkWorker/IPCClient.swift`:
Implement asynchronous Unix domain socket client reading/writing Big-Endian 4-byte framed messages.

**Step 2: Run test to verify framing**

Run: `(cd macos/link_worker && swift test)`  
Expected: PASS.

**Step 3: Commit**

```bash
git commit -am "feat(macos): implement link worker models and unix domain socket ipc"
```

---

### Task 3: ScreenCaptureKit Video & System Audio Capture

**Files:**
- Create: `macos/link_worker/Sources/LinkWorker/ScreenCapturer.swift`
- Create: `macos/link_worker/Sources/LinkWorker/AudioLoopback.swift`

**Step 1: Implement ScreenCapturer using ScreenCaptureKit**

In `macos/link_worker/Sources/LinkWorker/ScreenCapturer.swift`:
```swift
import Foundation
import ScreenCaptureKit
import CoreMedia

public protocol ScreenCaptureDelegate: AnyObject {
    func didCaptureVideoFrame(_ sampleBuffer: CMSampleBuffer)
    func didCaptureAudioFrame(_ sampleBuffer: CMSampleBuffer)
    func didFailCapture(error: Error)
}

@available(macOS 13.0, *)
public final class ScreenCapturer: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    public weak var delegate: ScreenCaptureDelegate?

    public func startCapture(display: SCDisplay) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.width = display.width * 2 // Retina scale
        config.height = display.height * 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.showsCursor = true

        // True system audio loopback without microphone
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true

        let s = SCStream(filter: filter, configuration: config, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "link.video.queue"))
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "link.audio.queue"))
        try await s.startCapture()
        self.stream = s
    }

    public func stopCapture() async {
        try? await stream?.stopCapture()
        stream = nil
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        switch type {
        case .screen:
            delegate?.didCaptureVideoFrame(sampleBuffer)
        case .audio:
            delegate?.didCaptureAudioFrame(sampleBuffer)
        @unknown default:
            break
        }
    }
}
```

**Step 2: Commit**

```bash
git commit -am "feat(macos): implement ScreenCaptureKit video and system audio capture"
```

---

### Task 4: WebRTC Bridge, VideoToolbox Encoder & DataChannel

**Files:**
- Create: `macos/link_worker/Sources/LinkWorker/WebRTCBridge.swift`
- Create: `macos/link_worker/Sources/LinkWorker/DataChannelHandler.swift`

**Step 1: Implement WebRTC Connection using WebRTC.framework**

Create `WebRTCBridge.swift` wrapping `RTCPeerConnection`:
- Configures ICE servers from `SessionOffer`.
- Configures `RTCRtpTransceiver` with `sendOnly` direction for video and audio.
- Feeds `CVPixelBuffer` from `didCaptureVideoFrame` directly into `RTCVideoSource`.
- Opens and listens to RTCDataChannel `link-control-v1`.
- Emits SDP Answer upon receiving remote Offer.

**Step 2: Implement Input Injection from DataChannel**

Create `DataChannelHandler.swift`:
- Parses incoming JSON control messages (`mouse_move`, `mouse_action`, `mouse_wheel`, `key_action`).
- Injects via `CGEventCreateMouseEvent` / `CGEventCreateKeyboardEvent`.
- Posts strictly to `kCGHIDEventTap` (single tap, eliminating double clicks).
- Checks `AXIsProcessTrusted()`.

**Step 3: Commit**

```bash
git commit -am "feat(macos): integrate WebRTC.framework and synthetic input injection"
```

---

### Task 5: Direct Recorder Ingestion & Keyframe Spooling

**Files:**
- Create: `macos/link_worker/Sources/LinkWorker/RecorderSink.swift`

**Step 1: Implement zero-copy frame snapshotting**

In `RecorderSink.swift`:
- Intercepts 1 frame per second from `CVPixelBuffer`.
- Uses `CIImage(cvPixelBuffer:)` with hardware GPU JPEG/WebP export.
- Queues frames to in-memory spool and posts to `ingestUrl` with `ingestToken`.
- Zero interaction with WindowServer or legacy `CGWindowListCreateImage`.

**Step 2: Commit**

```bash
git commit -am "feat(macos): add direct recorder sink from ScreenCaptureKit frames"
```

---

### Task 6: CLI Binary Entry Point, Packaging & CI Integration

**Files:**
- Create: `macos/link_worker/Sources/LinkWorker/main.swift`
- Modify: `scripts/build_dmg.sh`
- Modify: `.github/workflows/build_clients.yml`

**Step 1: Implement `main.swift`**

Parse `--link-host=unix:<socketPath>`, instantiate `IPCClient`, `ScreenCapturer`, and `WebRTCBridge`. Run `CFRunLoopRun()`.

**Step 2: Integrate into `build_clients.yml` and `build_dmg.sh`**

In `.github/workflows/build_clients.yml` (`build-macos` job):
```bash
(cd macos/link_worker && swift build -c release)
install -m 755 macos/link_worker/.build/release/link-worker-darwin 'build/macos/Build/Products/Release/Ligament 2FA.app/Contents/MacOS/link-worker-darwin'
codesign --force --sign - 'build/macos/Build/Products/Release/Ligament 2FA.app/Contents/MacOS/link-worker-darwin'
```

**Step 3: Verify clean build, analyzer, and tests**

Run:
```bash
flutter analyze
flutter test
(cd windows/link_agent && go test ./... && go vet ./...)
```
Expected: 0 errors, 0 warnings, all tests pass.

**Step 4: Commit and tag**

```bash
git commit -am "feat(macos): build and package link-worker-darwin in app bundle"
```
