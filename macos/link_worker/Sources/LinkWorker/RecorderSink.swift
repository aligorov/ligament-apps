import Foundation
import CoreMedia
import CoreVideo
import CoreImage
import ImageIO

public final class RecorderSink {
    private let config: RecordingConfig?
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private var lastCaptureTime: TimeInterval = 0
    private let queue = DispatchQueue(label: "com.ligament.link.recorder", qos: .utility)
    private let urlSession: URLSession

    public init(config: RecordingConfig?) {
        self.config = config
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = 10
        self.urlSession = URLSession(configuration: sessionConfig)
    }

    public func feedVideoFrame(_ sampleBuffer: CMSampleBuffer, isKeyframe: Bool = false) {
        guard let config = config, config.enabled == true,
              let ingestUrlString = config.ingestUrl,
              let ingestUrl = URL(string: ingestUrlString) else {
            return
        }

        let now = Date().timeIntervalSince1970
        // Capture at most 1 frame per second unless forced by keyframe
        guard isKeyframe || (now - lastCaptureTime >= 1.0) else {
            return
        }
        lastCaptureTime = now

        guard sampleBuffer.isValid,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        queue.async { [weak self] in
            guard let self = self else { return }
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            guard let jpegData = self.ciContext.jpegRepresentation(
                of: ciImage,
                colorSpace: CGColorSpaceCreateDeviceRGB(),
                options: [:]
            ) else {
                return
            }

            var request = URLRequest(url: ingestUrl)
            request.httpMethod = "POST"
            request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
            if let token = config.ingestToken, !token.isEmpty {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            request.httpBody = jpegData

            let task = self.urlSession.dataTask(with: request) { _, _, _ in }
            task.resume()
        }
    }
}
