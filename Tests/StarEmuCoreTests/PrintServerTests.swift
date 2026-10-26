import Foundation
import Testing
@testable import StarEmuCore

/// Collects PrintServer events into per-session byte buffers.
private actor EventLog {
    private(set) var opened: [SessionInfo] = []
    private(set) var bytes: [UUID: Data] = [:]
    private(set) var closed: [UUID] = []

    func consume(_ events: AsyncStream<PrintServer.Event>, untilClosed count: Int) async {
        for await event in events {
            switch event {
            case .opened(let info): opened.append(info)
            case .received(let id, let data): bytes[id, default: Data()].append(data)
            case .closed(let id): closed.append(id)
            case .listening, .failed, .stopped: break
            }
            if closed.count >= count { return }
        }
    }
}

@Suite(.timeLimit(.minutes(1)))
struct PrintServerTests {
    @Test func acceptsAndForwardsBytes() async throws {
        let server = PrintServer()
        let port = try await server.start(port: 0)
        defer { server.stop() }

        let payload = Data((0..<10_240).map { UInt8($0 % 251) })
        let log = EventLog()
        async let consumed: Void = log.consume(server.events, untilClosed: 1)
        try await TestSocket.send(payload, toPort: port)
        await consumed

        let session = try #require(await log.opened.first)
        #expect(session.localPort == port)
        #expect(session.remote.hasPrefix("127.0.0.1:"))
        #expect(await log.bytes[session.id] == payload)
        #expect(await log.closed == [session.id])
    }

    @Test func concurrentSessionsDoNotInterleave() async throws {
        let server = PrintServer()
        let port = try await server.start(port: 0)
        defer { server.stop() }

        let a = Data(repeating: 0x41, count: 50_000)
        let b = Data(repeating: 0x42, count: 50_000)
        let log = EventLog()
        async let consumed: Void = log.consume(server.events, untilClosed: 2)
        async let sendA: Void = TestSocket.send(a, toPort: port)
        async let sendB: Void = TestSocket.send(b, toPort: port)
        try await sendA
        try await sendB
        await consumed

        let received = Set(await log.bytes.values)
        #expect(received == [a, b])
    }

    @Test func reportsBoundPortForEphemeralRequest() async throws {
        let server = PrintServer()
        let port = try await server.start(port: 0)
        defer { server.stop() }
        #expect(port != 0)
    }

    @Test func portInUseThrows() async throws {
        let first = PrintServer()
        let port = try await first.start(port: 0)
        defer { first.stop() }

        let second = PrintServer()
        await #expect(throws: PrintServer.StartError.self) {
            _ = try await second.start(port: port, allowReuse: false)
        }
    }
}
