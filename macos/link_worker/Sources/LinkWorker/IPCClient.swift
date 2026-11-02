import Foundation
import Darwin

public enum IPCError: LocalizedError {
    case invalidSocketPath(String)
    case socketCreationFailed(Int32)
    case connectionFailed(Int32)
    case connectionClosed
    case frameExceedsLimit(Int)
    case readFailed(Int32)
    case writeFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidSocketPath(let path):
            return "Invalid unix socket path: \(path)"
        case .socketCreationFailed(let code):
            return "Socket creation failed with errno \(code)"
        case .connectionFailed(let code):
            return "Socket connection failed with errno \(code)"
        case .connectionClosed:
            return "Socket connection was closed by peer"
        case .frameExceedsLimit(let size):
            return "Frame size \(size) exceeds limit"
        case .readFailed(let code):
            return "Read failed with errno \(code)"
        case .writeFailed(let code):
            return "Write failed with errno \(code)"
        }
    }
}

public final class IPCClient {
    public static let maxFrameSize: Int = 512 * 1024 // 512 KB limit matching Go agent
    private var fd: Int32 = -1
    private let lock = NSLock()

    public init() {}

    deinit {
        close()
    }

    public func connect(socketPath: String) throws {
        lock.lock()
        defer { lock.unlock() }

        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }

        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        if sock < 0 {
            throw IPCError.socketCreationFailed(errno)
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard socketPath.utf8.count < maxLen else {
            Darwin.close(sock)
            throw IPCError.invalidSocketPath(socketPath)
        }

        withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
            _ = socketPath.withCString { cstr in
                strncpy(ptr, cstr, maxLen - 1)
            }
        }

        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                Darwin.connect(sock, saPtr, len)
            }
        }

        if connectResult != 0 {
            let err = errno
            Darwin.close(sock)
            throw IPCError.connectionFailed(err)
        }

        self.fd = sock
    }

    public func readFrame() throws -> Data {
        lock.lock()
        defer { lock.unlock() }

        guard fd >= 0 else { throw IPCError.connectionClosed }

        var header = [UInt8](repeating: 0, count: 4)
        try readExact(bytes: &header, count: 4)

        let length = Int(header[0]) << 24 | Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
        guard length > 0 && length <= Self.maxFrameSize else {
            throw IPCError.frameExceedsLimit(length)
        }

        var payload = [UInt8](repeating: 0, count: length)
        try readExact(bytes: &payload, count: length)

        return Data(payload)
    }

    public func sendFrame(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }

        guard fd >= 0 else { throw IPCError.connectionClosed }
        let length = data.count
        guard length > 0 && length <= Self.maxFrameSize else {
            throw IPCError.frameExceedsLimit(length)
        }

        var header = [
            UInt8((length >> 24) & 0xFF),
            UInt8((length >> 16) & 0xFF),
            UInt8((length >> 8) & 0xFF),
            UInt8(length & 0xFF)
        ]

        try writeExact(bytes: &header, count: 4)
        var bytes = Array(data)
        try writeExact(bytes: &bytes, count: length)
    }

    public func send<T: Encodable>(_ object: T) throws {
        let encoder = JSONEncoder()
        let data = try encoder.encode(object)
        try sendFrame(data)
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }

        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }

    private func readExact(bytes: inout [UInt8], count: Int) throws {
        var remaining = count
        var offset = 0
        while remaining > 0 {
            let n = bytes.withUnsafeMutableBytes { raw in
                Darwin.read(fd, raw.baseAddress! + offset, remaining)
            }
            if n == 0 {
                throw IPCError.connectionClosed
            }
            if n < 0 {
                let err = errno
                if err == EINTR { continue }
                throw IPCError.readFailed(err)
            }
            offset += n
            remaining -= n
        }
    }

    private func writeExact(bytes: inout [UInt8], count: Int) throws {
        var remaining = count
        var offset = 0
        while remaining > 0 {
            let n = bytes.withUnsafeBytes { raw in
                Darwin.write(fd, raw.baseAddress! + offset, remaining)
            }
            if n <= 0 {
                let err = errno
                if err == EINTR { continue }
                throw IPCError.writeFailed(err)
            }
            offset += n
            remaining -= n
        }
    }
}
