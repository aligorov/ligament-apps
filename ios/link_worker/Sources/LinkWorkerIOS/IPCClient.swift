import Foundation
import Darwin

public final class IPCClient {
    private var fileDescriptor: Int32 = -1
    private let maxFrameSize: Int = 512 * 1024

    public init() {}

    deinit {
        close()
    }

    public func connect(socketPath: String) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "Failed to create socket"])
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)

        let pathBytes = socketPath.utf8CString
        if pathBytes.count > maxLen {
            Darwin.close(fd)
            throw NSError(domain: "IPCClient", code: 1, userInfo: [NSLocalizedDescriptionKey: "Socket path exceeds sun_path length"])
        }

        withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
            for (index, byte) in pathBytes.enumerated() {
                ptr.advanced(by: index).pointee = byte
            }
        }

        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                Darwin.connect(fd, saPtr, len)
            }
        }

        if result < 0 {
            let err = errno
            Darwin.close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err), userInfo: [NSLocalizedDescriptionKey: "Failed to connect to Unix domain socket at \(socketPath)"])
        }

        self.fileDescriptor = fd
    }

    public func readFrame() throws -> Data {
        guard fileDescriptor >= 0 else {
            throw NSError(domain: "IPCClient", code: 2, userInfo: [NSLocalizedDescriptionKey: "Socket not connected"])
        }

        var header = [UInt8](repeating: 0, count: 4)
        try readExact(bytes: &header, count: 4)

        let length = Int(header[0]) << 24 | Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
        if length <= 0 || length > maxFrameSize {
            throw NSError(domain: "IPCClient", code: 3, userInfo: [NSLocalizedDescriptionKey: "Invalid frame size: \(length)"])
        }

        var buffer = [UInt8](repeating: 0, count: length)
        try readExact(bytes: &buffer, count: length)

        return Data(buffer)
    }

    public func send<T: Encodable>(_ message: T) throws {
        let encoder = JSONEncoder()
        let payload = try encoder.encode(message)
        try sendFrame(payload)
    }

    public func sendFrame(_ data: Data) throws {
        guard fileDescriptor >= 0 else {
            throw NSError(domain: "IPCClient", code: 2, userInfo: [NSLocalizedDescriptionKey: "Socket not connected"])
        }
        let length = data.count
        if length == 0 || length > maxFrameSize {
            throw NSError(domain: "IPCClient", code: 3, userInfo: [NSLocalizedDescriptionKey: "Invalid frame size: \(length)"])
        }

        var header = [UInt8](repeating: 0, count: 4)
        header[0] = UInt8((length >> 24) & 0xFF)
        header[1] = UInt8((length >> 16) & 0xFF)
        header[2] = UInt8((length >> 8) & 0xFF)
        header[3] = UInt8(length & 0xFF)

        try writeExact(bytes: header, count: 4)
        try data.withUnsafeBytes { rawBuffer in
            guard let ptr = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            try writeExact(bytes: ptr, count: length)
        }
    }

    public func close() {
        if fileDescriptor >= 0 {
            Darwin.close(fileDescriptor)
            fileDescriptor = -1
        }
    }

    private func readExact(bytes: UnsafeMutablePointer<UInt8>, count: Int) throws {
        var totalRead = 0
        while totalRead < count {
            let n = Darwin.read(fileDescriptor, bytes.advanced(by: totalRead), count - totalRead)
            if n > 0 {
                totalRead += n
            } else if n == 0 {
                throw NSError(domain: "IPCClient", code: 4, userInfo: [NSLocalizedDescriptionKey: "Socket closed by peer"])
            } else {
                if errno == EINTR { continue }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "Read error"])
            }
        }
    }

    private func writeExact(bytes: UnsafePointer<UInt8>, count: Int) throws {
        var totalWritten = 0
        while totalWritten < count {
            let n = Darwin.write(fileDescriptor, bytes.advanced(by: totalWritten), count - totalWritten)
            if n > 0 {
                totalWritten += n
            } else {
                if errno == EINTR { continue }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "Write error"])
            }
        }
    }
}
