import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreGraphics

public protocol ScreenCaptureDelegate: AnyObject {
    func didCaptureVideoFrame(_ sampleBuffer: CMSampleBuffer)
    func didCaptureAudioFrame(_ sampleBuffer: CMSampleBuffer)
    func didFailCapture(error: Error)
    func didPauseCapture(reason: String)
    func didResumeCapture()
}

@available(macOS 13.0, *)
public final class ScreenCapturer: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let videoQueue = DispatchQueue(label: "com.ligament.link.video", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "com.ligament.link.audio", qos: .userInteractive)
    public weak var delegate: ScreenCaptureDelegate?

    public private(set) var activeDisplayBounds: CGRect = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    private var currentDisplayId: CGDirectDisplayID?
    private var currentCaptureAudio: Bool = true
    private var isRecovering: Bool = false

    public override init() {
        super.init()
    }

    public func startCapture(displayId: CGDirectDisplayID? = nil, captureAudio: Bool = true) async throws {
        self.currentDisplayId = displayId
        self.currentCaptureAudio = captureAudio

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        
        let targetDisplay: SCDisplay
        if let displayId = displayId, let found = content.displays.first(where: { $0.displayID == displayId }) {
            targetDisplay = found
        } else if let main = content.displays.first {
            targetDisplay = main
        } else {
            throw NSError(domain: "ScreenCapturer", code: 1, userInfo: [NSLocalizedDescriptionKey: "No active displays found"])
        }

        self.activeDisplayBounds = targetDisplay.frame

        let filter = SCContentFilter(display: targetDisplay, excludingWindows: [])

        let config = SCStreamConfiguration()
        var w = targetDisplay.width * 2
        var h = targetDisplay.height * 2
        // Cap maximum dimension to 3840 wide to avoid GPU VideoToolbox overload on 5K/6K displays
        if w > 3840 {
            let scale = 3840.0 / Double(w)
            w = 3840
            h = max(720, Int(Double(h) * scale))
        }
        config.width = w
        config.height = h
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.showsCursor = true

        if captureAudio {
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
        }

        let scStream = SCStream(filter: filter, configuration: config, delegate: self)
        try scStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        if captureAudio {
            try scStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        }

        try await scStream.startCapture()
        self.stream = scStream
    }

    public func stopCapture() async {
        if let s = stream {
            try? await s.stopCapture()
            stream = nil
        }
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        switch type {
        case .screen:
            delegate?.didCaptureVideoFrame(sampleBuffer)
        case .audio:
            delegate?.didCaptureAudioFrame(sampleBuffer)
        case .microphone:
            break
        @unknown default:
            break
        }
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        let nsError = error as NSError
        // Handle transient display reconfigurations / sleep (-3808: resolution changed, -3818: display not available)
        if nsError.domain == SCStreamErrorDomain && (nsError.code == -3808 || nsError.code == -3818) {
            self.stream = nil
            delegate?.didPauseCapture(reason: "display_reconfiguring_\(nsError.code)")
            scheduleStreamRecovery()
            return
        }
        delegate?.didFailCapture(error: error)
    }

    private func scheduleStreamRecovery() {
        guard !isRecovering else { return }
        isRecovering = true
        Task { [weak self] in
            // Wait 1.5s for display hardware/topology to settle
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self = self else { return }
            do {
                try await self.startCapture(displayId: self.currentDisplayId, captureAudio: self.currentCaptureAudio)
                self.isRecovering = false
                self.delegate?.didResumeCapture()
            } catch {
                self.isRecovering = false
                self.delegate?.didFailCapture(error: error)
            }
        }
    }
}
