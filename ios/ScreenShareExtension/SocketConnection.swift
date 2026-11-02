import Foundation
import Darwin

public protocol SocketConnectionDelegate: AnyObject {
    func socketDidOpen()
    func socketDidClose(error: Error?)
}

public final class SocketConnection {
    private let filePath: String
    private var fileDescriptor: Int32 = -1
    private let queue = DispatchQueue(label: "com.ligament.screenshare.socket", qos: .userInteractive)
    public weak var delegate: SocketConnectionDelegate?

    public init(filePath: String) {
        self.filePath = filePath
    }

    public func open() {
        queue.async { [weak self] in
            guard let self = self, self.fileDescriptor == -1 else { return }
            
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else {
                self.delegate?.socketDidClose(error: NSError(domain: NSPOSIXErrorDomain, code: Int(errno)))
                return
            }

            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let maxLen = MemoryLayout.size(ofValue: addr.sun_path)

            let pathBytes = self.filePath.utf8CString
            if pathBytes.count > maxLen {
                close(fd)
                self.delegate?.socketDidClose(error: NSError(domain: "SocketConnection", code: 1, userInfo: [NSLocalizedDescriptionKey: "Socket path too long"]))
                return
            }

            withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
                for (index, byte) in pathBytes.enumerated() {
                    ptr.advanced(by: index).pointee = byte
                }
            }

            let len = socklen_t(MemoryLayout<sockaddr_un>.size)
            let result = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                    connect(fd, saPtr, len)
                }
            }

            if result == 0 {
                self.fileDescriptor = fd
                self.delegate?.socketDidOpen()
            } else {
                close(fd)
                self.delegate?.socketDidClose(error: NSError(domain: NSPOSIXErrorDomain, code: Int(errno)))
            }
        }
    }

    public func closeSocket() {
        queue.async { [weak self] in
            guard let self = self, self.fileDescriptor >= 0 else { return }
            close(self.fileDescriptor)
            self.fileDescriptor = -1
            self.delegate?.socketDidClose(error: nil)
        }
    }

    public func send(data: Data) -> Bool {
        guard fileDescriptor >= 0 else { return false }
        return data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return false }
            var totalSent = 0
            let totalLength = buffer.count

            while totalSent < totalLength {
                let bytesSent = Darwin.send(
                    fileDescriptor,
                    baseAddress.advanced(by: totalSent),
                    totalLength - totalSent,
                    0
                )
                if bytesSent <= 0 {
                    if errno == EINTR { continue }
                    return false
                }
                totalSent += bytesSent
            }
            return true
        }
    }
}
