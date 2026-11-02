import Foundation
import ReplayKit
import CoreMedia

public protocol ReplayKitCaptureDelegate: AnyObject {
    func didCaptureVideoFrame(_ sampleBuffer: CMSampleBuffer)
    func didCaptureAudioFrame(_ sampleBuffer: CMSampleBuffer)
    func didFailCapture(error: Error)
}

public final class ReplayKitCapturer: NSObject {
    private let recorder = RPScreenRecorder.shared()
    public weak var delegate: ReplayKitCaptureDelegate?
    private var isRecording = false

    public override init() {
        super.init()
    }

    public func startInAppCapture() async throws {
        guard !isRecording else { return }
        guard recorder.isAvailable else {
            throw NSError(domain: "ReplayKitCapturer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Screen recorder not available"])
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            recorder.startCapture(handler: { [weak self] sampleBuffer, sampleType, error in
                if let error = error {
                    self?.delegate?.didFailCapture(error: error)
                    return
                }
                guard sampleBuffer.isValid else { return }

                switch sampleType {
                case .video:
                    self?.delegate?.didCaptureVideoFrame(sampleBuffer)
                case .audioApp, .audioMic:
                    self?.delegate?.didCaptureAudioFrame(sampleBuffer)
                @unknown default:
                    break
                }
            }, completionHandler: { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            })
        }
        self.isRecording = true
    }

    public func stopInAppCapture() async {
        guard isRecording else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            recorder.stopCapture { _ in
                continuation.resume()
            }
        }
        self.isRecording = false
    }

    public func feedExternalSampleBuffer(_ sampleBuffer: CMSampleBuffer, of type: RPSampleBufferType) {
        guard sampleBuffer.isValid else { return }
        switch type {
        case .video:
            delegate?.didCaptureVideoFrame(sampleBuffer)
        case .audioApp, .audioMic:
            delegate?.didCaptureAudioFrame(sampleBuffer)
        @unknown default:
            break
        }
    }
}
