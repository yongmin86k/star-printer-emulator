import Foundation
import Testing
@testable import StarEmuCore

@Suite(.timeLimit(.minutes(1)))
struct JobAssemblerTests {
    let store: JobStore

    init() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("staremu-tests-\(UUID().uuidString)", isDirectory: true)
        store = try JobStore(directory: dir)
    }

    private func session(_ remote: String = "10.0.0.2:5000") -> SessionInfo {
        SessionInfo(id: UUID(), remote: remote, localPort: 9100)
    }

    @Test func closeFinishesJob() async throws {
        let assembler = JobAssembler(store: store, idleTimeout: .seconds(30))
        var jobs = assembler.jobs.makeAsyncIterator()
        let s = session()

        await assembler.opened(s)
        await assembler.received(s.id, Data("AB".utf8))
        await assembler.received(s.id, Data("C".utf8))
        await assembler.closed(s.id)

        let job = try #require(await jobs.next())
        #expect(job.byteCount == 3)
        #expect(job.remote == s.remote)
        #expect(try store.data(for: job) == Data("ABC".utf8))
    }

    @Test func idleFinishesJobAndSessionContinues() async throws {
        let assembler = JobAssembler(store: store, idleTimeout: .milliseconds(100))
        var jobs = assembler.jobs.makeAsyncIterator()
        let s = session()

        await assembler.opened(s)
        await assembler.received(s.id, Data("first".utf8))
        let first = try #require(await jobs.next())   // fires after ~100 ms idle

        await assembler.received(s.id, Data("second".utf8))
        await assembler.closed(s.id)
        let second = try #require(await jobs.next())

        #expect(try store.data(for: first) == Data("first".utf8))
        #expect(try store.data(for: second) == Data("second".utf8))
    }

    @Test func bytesResetIdleTimer() async throws {
        let assembler = JobAssembler(store: store, idleTimeout: .milliseconds(300))
        var jobs = assembler.jobs.makeAsyncIterator()
        let s = session()

        await assembler.opened(s)
        for chunk in ["a", "b", "c"] {
            await assembler.received(s.id, Data(chunk.utf8))
            try await Task.sleep(for: .milliseconds(100))   // < idle timeout each time
        }
        await assembler.closed(s.id)

        let job = try #require(await jobs.next())
        #expect(try store.data(for: job) == Data("abc".utf8))
    }

    @Test func emptySessionMakesNoJob() async throws {
        let assembler = JobAssembler(store: store, idleTimeout: .milliseconds(50))
        let s = session()

        await assembler.opened(s)
        await assembler.closed(s.id)
        try await Task.sleep(for: .milliseconds(150))

        #expect(try store.loadAll().isEmpty)
    }

    @Test func sessionsAreIndependent() async throws {
        let assembler = JobAssembler(store: store, idleTimeout: .seconds(30))
        var jobs = assembler.jobs.makeAsyncIterator()
        let a = session("10.0.0.2:1"), b = session("10.0.0.3:2")

        await assembler.opened(a)
        await assembler.opened(b)
        await assembler.received(a.id, Data("A1".utf8))
        await assembler.received(b.id, Data("B1".utf8))
        await assembler.received(a.id, Data("A2".utf8))
        await assembler.closed(b.id)
        await assembler.closed(a.id)

        let first = try #require(await jobs.next())
        let second = try #require(await jobs.next())
        #expect(try store.data(for: first) == Data("B1".utf8))
        #expect(try store.data(for: second) == Data("A1A2".utf8))
    }

    @Test func unknownSessionIsIgnored() async throws {
        let assembler = JobAssembler(store: store, idleTimeout: .milliseconds(50))
        await assembler.received(UUID(), Data("x".utf8))
        await assembler.closed(UUID())
        try await Task.sleep(for: .milliseconds(150))

        #expect(try store.loadAll().isEmpty)
    }
}
