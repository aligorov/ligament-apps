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
    private let videoQueue = DispatchQueue(label: "com.ligament.link.video", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "com.ligament.link.audio", qos: .userInteractive)
    public weak var delegate: ScreenCaptureDelegate?

    public override init() {
        super.init()
    }

    public func startCapture(displayId: CGDirectDisplayID? = nil, captureAudio: Bool = true) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        
        let targetDisplay: SCDisplay
        if let displayId = displayId, let found = content.displays.first(where: { $0.displayID == displayId }) {
            targetDisplay = found
        } else if let main = content.displays.first {
            targetDisplay = main
        } else {
            throw NSError(domain: "ScreenCapturer", code: 1, userInfo: [NSLocalizedDescriptionKey: "No active displays found"])
        }

        let filter = SCContentFilter(display: targetDisplay, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.width = targetDisplay.width * 2
        config.height = targetDisplay.height * 2
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
        delegate?.didFailCapture(error: error)
    }
}
