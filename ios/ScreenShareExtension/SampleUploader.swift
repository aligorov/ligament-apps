import Foundation
import CoreMedia
import CoreVideo

public final class SampleUploader {
    private let connection: SocketConnection
    private var lastSendTime: TimeInterval = 0
    private let minInterval: TimeInterval = 1.0 / 20.0 // Throttle to 20 fps to conserve memory under 50MB Jetsam
    private let queue = DispatchQueue(label: "com.ligament.screenshare.uploader", qos: .userInteractive)

    public init(connection: SocketConnection) {
        self.connection = connection
    }

    public func send(sampleBuffer: CMSampleBuffer) {
        let now = CACurrentMediaTime()
        guard now - lastSendTime >= minInterval else { return }
        lastSendTime = now

        guard sampleBuffer.isValid,
              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        queue.async { [weak self] in
            guard let self = self else { return }
            autoreleasepool {
                CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)
                defer { CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly) }

                let width = Int32(CVPixelBufferGetWidth(imageBuffer))
                let height = Int32(CVPixelBufferGetHeight(imageBuffer))
                let pixelFormat = CVPixelBufferGetPixelFormatType(imageBuffer)

                // Header format: [Width: UInt32][Height: UInt32][PixelFormat: UInt32][PayloadSize: UInt32]
                let planeCount = CVPixelBufferGetPlaneCount(imageBuffer)
                var payloadData = Data()

                if planeCount == 0 {
                    guard let baseAddress = CVPixelBufferGetBaseAddress(imageBuffer) else { return }
                    let bytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer)
                    let totalBytes = bytesPerRow * Int(height)
                    payloadData.append(Data(bytes: baseAddress, count: totalBytes))
                } else {
                    for plane in 0..<planeCount {
                        guard let planeAddress = CVPixelBufferGetBaseAddressOfPlane(imageBuffer, plane) else { return }
                        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(imageBuffer, plane)
                        let planeHeight = CVPixelBufferGetHeightOfPlane(imageBuffer, plane)
                        let totalBytes = bytesPerRow * planeHeight
                        payloadData.append(Data(bytes: planeAddress, count: totalBytes))
                    }
                }

                var header = Data(capacity: 16)
                var w = CFSwapInt32HostToBig(UInt32(width))
                var h = CFSwapInt32HostToBig(UInt32(height))
                var fmt = CFSwapInt32HostToBig(UInt32(pixelFormat))
                var sz = CFSwapInt32HostToBig(UInt32(payloadData.count))

                header.append(UnsafeBufferPointer(start: &w, count: 1))
                header.append(UnsafeBufferPointer(start: &h, count: 1))
                header.append(UnsafeBufferPointer(start: &fmt, count: 1))
                header.append(UnsafeBufferPointer(start: &sz, count: 1))

                var packet = header
                packet.append(payloadData)

                _ = self.connection.send(data: packet)
            }
        }
    }
}
