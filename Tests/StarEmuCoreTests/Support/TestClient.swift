import Darwin
import Foundation

/// Blocking TCP/UDP clients for integration tests (each call runs off the cooperative pool).
final class TCPTestClient: @unchecked Sendable {
    private let fd: Int32

    init(port: UInt16, host: String = "127.0.0.1", timeout: TimeInterval = 2) throws {
        fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in.loopback(port: port, host: host)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else { throw TestSocket.Failure(description: "connect: \(errno)") }
    }

    deinit { close(fd) }

    func send(_ data: Data) {
        data.withUnsafeBytes { _ = Darwin.send(fd, $0.baseAddress, $0.count, 0) }
    }

    /// Reads exactly `count` bytes, or fewer on timeout / EOF.
    func read(_ count: Int) async -> Data {
        await Task.detached { [fd] in
            var out = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while out.count < count {
                let n = recv(fd, &buffer, min(buffer.count, count - out.count), 0)
                guard n > 0 else { break }
                out.append(contentsOf: buffer.prefix(n))
            }
            return out
        }.value
    }

    /// True when the peer has closed (recv returns 0 before the timeout).
    func readEOF() async -> Bool {
        await Task.detached { [fd] in
            var byte: UInt8 = 0
            return recv(fd, &byte, 1, 0) == 0
        }.value
    }
}

enum UDPTestClient {
    /// Sends one datagram and returns the first reply within `timeout` (nil if none).
    static func exchange(_ data: Data, port: UInt16, timeout: TimeInterval = 0.5) async -> Data? {
        await Task.detached {
            let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            defer { close(fd) }
            var tv = timeval(tv_sec: 0, tv_usec: Int32(timeout * 1_000_000))
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            var addr = sockaddr_in.loopback(port: port)
            _ = data.withUnsafeBytes { bytes in
                withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            var buffer = [UInt8](repeating: 0, count: 2048)
            let n = recv(fd, &buffer, buffer.count, 0)
            return n > 0 ? Data(buffer.prefix(n)) : nil
        }.value
    }
}

extension sockaddr_in {
    static func loopback(port: UInt16, host: String = "127.0.0.1") -> sockaddr_in {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        inet_pton(AF_INET, host, &addr.sin_addr)
        return addr
    }
}
