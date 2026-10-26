import Darwin
import Foundation
import os

/// Answers Star discovery broadcasts and unicasts on UDP 22222. Uses a BSD socket because receiving
/// broadcasts reliably needs SO_BROADCAST / SO_REUSEPORT. All state is confined to `queue`.
public final class DiscoveryResponder: @unchecked Sendable {
    public struct Request: Sendable {
        public let peer: String
        public let answered: Bool
    }

    public enum StartError: Error, CustomStringConvertible {
        case socket(String)
        public var description: String {
            switch self {
            case .socket(let reason): "Discovery listener failed: \(reason)"
            }
        }
    }

    /// Called for every discovery datagram (answered or not), on the responder's queue.
    public var onRequest: (@Sendable (Request) -> Void)?

    private let queue = DispatchQueue(label: "dev.staremu.discovery")
    private let log = Logger(subsystem: "dev.staremu", category: "Discovery")
    private let makeReply: @Sendable (_ peerIP: String) -> Data?
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private var lastReply: [String: Date] = [:]

    /// `makeReply` builds the 302-byte reply for a peer; return nil to stay silent.
    public init(makeReply: @escaping @Sendable (_ peerIP: String) -> Data?) {
        self.makeReply = makeReply
    }

    /// Binds UDP `port` (0 = ephemeral, for tests) and returns the bound port.
    @discardableResult
    public func start(port: UInt16 = DeviceProfile.mcPrint3.discoveryPort) throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw StartError.socket("socket(): \(String(cString: strerror(errno)))") }
        var one: Int32 = 1
        for option in [SO_REUSEADDR, SO_REUSEPORT, SO_BROADCAST] {
            setsockopt(fd, SOL_SOCKET, option, &one, socklen_t(MemoryLayout<Int32>.size))
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: INADDR_ANY)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else {
            let reason = String(cString: strerror(errno))
            close(fd)
            throw StartError.socket("bind(\(port)): \(reason)")
        }
        let actualPort = Self.localPort(fd)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.receive() }
        source.setCancelHandler { close(fd) }
        queue.sync {
            self.fd = fd
            self.source = source
        }
        source.resume()
        log.info("Discovery listening on UDP \(actualPort)")
        return actualPort
    }

    public func stop() {
        queue.sync {
            source?.cancel()
            source = nil
            fd = -1
        }
    }

    // MARK: - On queue

    private func receive() {
        var buffer = [UInt8](repeating: 0, count: 2048)
        var peer = sockaddr_in()
        var peerLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let count = withUnsafeMutablePointer(to: &peer) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &peerLength) }
        }
        guard count > 0 else { return }
        let request = Data(buffer.prefix(count))
        let peerIP = String(cString: inet_ntoa(peer.sin_addr))
        let peerKey = "\(peerIP):\(UInt16(bigEndian: peer.sin_port))"

        guard DiscoveryProtocol.shouldAnswer(request), !rateLimited(peerKey), let reply = makeReply(peerIP) else {
            onRequest?(Request(peer: peerKey, answered: false))
            return
        }
        let sent = reply.withUnsafeBytes { bytes in
            withUnsafePointer(to: &peer) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, bytes.baseAddress, bytes.count, 0, $0, peerLength) }
            }
        }
        if sent < 0 { log.error("sendto \(peerKey, privacy: .public) failed: \(String(cString: strerror(errno)), privacy: .public)") }
        onRequest?(Request(peer: peerKey, answered: sent >= 0))
    }

    /// At most one reply per peer per 100 ms (the SDK repeats every ~0.5 s).
    private func rateLimited(_ peer: String) -> Bool {
        let now = Date()
        defer { lastReply[peer] = now }
        guard let last = lastReply[peer] else { return false }
        return now.timeIntervalSince(last) < 0.1
    }

    private static func localPort(_ fd: Int32) -> UInt16 {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        return UInt16(bigEndian: address.sin_port)
    }
}
