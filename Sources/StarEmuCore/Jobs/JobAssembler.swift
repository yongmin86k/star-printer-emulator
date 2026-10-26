import Foundation
import os

/// One accepted TCP connection.
public struct SessionInfo: Sendable, Hashable {
    public let id: UUID
    public let remote: String
    public let localPort: UInt16

    public init(id: UUID, remote: String, localPort: UInt16) {
        self.id = id
        self.remote = remote
        self.localPort = localPort
    }
}

/// Turns per-session byte streams into stored jobs.
///
/// A job ends when its connection closes, or when no bytes arrive for `idleTimeout`
/// (the SDK may keep one connection open across prints). Empty buffers never become jobs.
public actor JobAssembler {
    private struct Pending {
        let info: SessionInfo
        var buffer = Data()
        var firstByteAt: Date?
        var idleTask: Task<Void, Never>?
        var generation = 0
    }

    public nonisolated let jobs: AsyncStream<Job>
    private let continuation: AsyncStream<Job>.Continuation
    private let store: JobStore
    private let idleTimeout: Duration
    private var sessions: [UUID: Pending] = [:]
    private let log = Logger(subsystem: "dev.staremu", category: "JobAssembler")

    public init(store: JobStore, idleTimeout: Duration = .seconds(1)) {
        self.store = store
        self.idleTimeout = idleTimeout
        (jobs, continuation) = AsyncStream.makeStream(of: Job.self)
    }

    deinit {
        continuation.finish()
    }

    /// Routes session events from a `PrintServer`; other events are ignored.
    public func handle(_ event: PrintServer.Event) {
        switch event {
        case .opened(let info): opened(info)
        case .received(let id, let data): received(id, data)
        case .closed(let id): closed(id)
        case .listening, .failed, .stopped: break
        }
    }

    public func opened(_ info: SessionInfo) {
        sessions[info.id] = Pending(info: info)
    }

    public func received(_ id: UUID, _ data: Data) {
        guard var pending = sessions[id], !data.isEmpty else { return }
        if pending.buffer.isEmpty { pending.firstByteAt = Date() }
        pending.buffer.append(data)
        pending.generation += 1
        pending.idleTask?.cancel()
        pending.idleTask = idleTimer(for: id, generation: pending.generation)
        sessions[id] = pending
    }

    public func closed(_ id: UUID) {
        guard let pending = sessions.removeValue(forKey: id) else { return }
        pending.idleTask?.cancel()
        flush(pending)
    }

    /// Ends the current job on a session now (e.g. after the SDK's end-of-document marker).
    public func finishJob(_ id: UUID) {
        guard let pending = sessions[id] else { return }
        pending.idleTask?.cancel()
        flush(pending)
        sessions[id] = Pending(info: pending.info, generation: pending.generation + 1)
    }

    private func idleTimer(for id: UUID, generation: Int) -> Task<Void, Never> {
        let timeout = idleTimeout
        return Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.idleExpired(id, generation: generation)
        }
    }

    private func idleExpired(_ id: UUID, generation: Int) {
        guard let pending = sessions[id], pending.generation == generation else { return }
        flush(pending)
        sessions[id] = Pending(info: pending.info, generation: pending.generation)
    }

    private func flush(_ pending: Pending) {
        guard !pending.buffer.isEmpty, Self.isJob(pending.buffer) else { return }
        let meta = JobMeta(
            receivedAt: pending.firstByteAt ?? Date(),
            remote: pending.info.remote,
            localPort: pending.info.localPort
        )
        do {
            continuation.yield(try store.save(pending.buffer, meta: meta))
        } catch {
            log.error("Failed to store job from \(pending.info.remote, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// False for buffers holding only session traffic (keep-alive NULs, status requests, ASB/ETB control, job prologue),
    /// which the SDK sends constantly and which would otherwise appear as empty jobs. True for anything printable and
    /// for every SDK document (`ESC GS ETX 3`), even an empty one: that's a print call, e.g. text sent to a TSP100IIIW.
    static func isJob(_ data: Data) -> Bool {
        StarPRNTParser.parse(data).contains { $0.producesOutput || $0 == .documentControl(3) }
    }
}
