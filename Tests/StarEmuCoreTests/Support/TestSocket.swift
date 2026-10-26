import Darwin
import Foundation

/// Minimal blocking TCP client for tests: connect, send, close (FIN). Runs off the cooperative pool.
enum TestSocket {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func send(_ data: Data, toPort port: UInt16, host: String = "127.0.0.1") async throws {
        try await Task.detached {
            let fd = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
            guard fd >= 0 else { throw Failure(description: "socket() failed: \(errno)") }
            defer { Darwin.close(fd) }

            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            inet_pton(AF_INET, host, &addr.sin_addr)

            let connected = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard connected == 0 else { throw Failure(description: "connect() failed: \(errno)") }

            try data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let n = Darwin.send(fd, raw.baseAddress! + offset, raw.count - offset, 0)
                    guard n > 0 else { throw Failure(description: "send() failed: \(errno)") }
                    offset += n
                }
            }
            Darwin.shutdown(fd, SHUT_WR)
        }.value
    }
}
