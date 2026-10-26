import Foundation
import Network
import os

/// TCP listener (port 9100 by default). One session per accepted connection; bytes are
/// reported as events. A server is one-shot: after `stop()` create a new one.
///
/// All mutable state is confined to `queue`, hence `@unchecked Sendable`.
public final class PrintServer: @unchecked Sendable {
    public enum Event: Sendable {
        case listening(port: UInt16)
        case failed(String)
        case stopped
        case opened(SessionInfo)
        case received(UUID, Data)
        case closed(UUID)
    }

    public enum StartError: Error, CustomStringConvertible {
        case failed(String)

        public var description: String {
            switch self {
            case .failed(let reason): "Could not start listener: \(reason)"
            }
        }
    }

    /// Single consumer. Finishes after the listener is cancelled.
    public let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation
    private let queue = DispatchQueue(label: "dev.staremu.printserver")
    private let log = Logger(subsystem: "dev.staremu", category: "PrintServer")
    private var listener: NWListener?
    private var boundPort: UInt16 = 0
    private var connections: [UUID: NWConnection] = [:]

    public init() {
        (events, continuation) = AsyncStream.makeStream(of: Event.self)
    }

    /// Starts listening and returns the bound port (useful with `port: 0` for an ephemeral port).
    /// `allowReuse` sets SO_REUSEADDR/SO_REUSEPORT; leave it off so a second emulator on the same port fails loudly.
    @discardableResult
    public func start(port: UInt16, allowReuse: Bool = false) async throws -> UInt16 {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = allowReuse
        let listener: NWListener
        do {
            listener = try NWListener(using: params, on: port == 0 ? .any : NWEndpoint.Port(rawValue: port)!)
        } catch {
            throw StartError.failed(error.localizedDescription)
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }

        return try await withCheckedThrowingContinuation { (startResult: CheckedContinuation<UInt16, Error>) in
            let resume = ResumeOnce(startResult)
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, let listener else { return }
                self.handle(state, of: listener, resume: resume)
            }
            queue.async { self.listener = listener }
            listener.start(queue: queue)
        }
    }

    /// Writes bytes to a session; with `thenClose`, sends FIN after the data and ends the session.
    public func send(_ data: Data, to id: UUID, thenClose: Bool = false) {
        queue.async { [weak self] in
            guard let self, let connection = self.connections[id] else { return }
            let context: NWConnection.ContentContext = thenClose ? .finalMessage : .defaultMessage
            connection.send(content: data, contentContext: context, isComplete: thenClose, completion: .contentProcessed { [weak self] error in
                if let error { self?.log.error("send failed: \(error.localizedDescription, privacy: .public)") }
                if thenClose { self?.finish(id) }
            })
        }
    }

    /// Ends a session (the client sees FIN).
    public func close(_ id: UUID) {
        queue.async { self.finish(id) }
    }

    public func stop() {
        queue.async {
            self.connections.values.forEach { $0.cancel() }
            self.connections.removeAll()
            self.listener?.cancel()
        }
    }

    // MARK: - Listener (on queue)

    private func handle(_ state: NWListener.State, of listener: NWListener, resume: ResumeOnce) {
        switch state {
        case .ready:
            boundPort = listener.port?.rawValue ?? 0
            log.info("Listening on \(self.boundPort)")
            continuation.yield(.listening(port: boundPort))
            resume.callAsFunction(.success(boundPort))
        case .failed(let error), .waiting(let error):
            log.error("Listener failed: \(error.localizedDescription, privacy: .public)")
            continuation.yield(.failed(error.localizedDescription))
            resume.callAsFunction(.failure(StartError.failed(error.localizedDescription)))
            listener.cancel()
        case .cancelled:
            self.listener = nil
            continuation.yield(.stopped)
            continuation.finish()
            resume.callAsFunction(.failure(StartError.failed("cancelled")))
        default:
            break
        }
    }

    // MARK: - Sessions (on queue)

    private func accept(_ connection: NWConnection) {
        let info = SessionInfo(id: UUID(), remote: Self.describe(connection.endpoint), localPort: boundPort)
        connections[info.id] = connection
        continuation.yield(.opened(info))
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.finish(info.id) }
        }
        connection.start(queue: queue)
        receive(on: connection, id: info.id)
    }

    private func receive(on connection: NWConnection, id: UUID) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.continuation.yield(.received(id, data)) }
            guard !isComplete, error == nil else { return self.finish(id) }
            self.receive(on: connection, id: id)
        }
    }

    /// Idempotent: emits `.closed` once per session.
    private func finish(_ id: UUID) {
        guard let connection = connections.removeValue(forKey: id) else { return }
        connection.cancel()
        continuation.yield(.closed(id))
    }

    private static func describe(_ endpoint: NWEndpoint) -> String {
        guard case .hostPort(let host, let port) = endpoint else { return "\(endpoint)" }
        switch host {
        case .ipv4(let address): return "\(address):\(port.rawValue)"
        case .ipv6(let address): return "[\(address)]:\(port.rawValue)"
        default: return "\(host):\(port.rawValue)"
        }
    }
}

/// Resumes a continuation at most once. Only touched on the server queue.
private final class ResumeOnce: @unchecked Sendable {
    private var continuation: CheckedContinuation<UInt16, Error>?

    init(_ continuation: CheckedContinuation<UInt16, Error>) {
        self.continuation = continuation
    }

    func callAsFunction(_ result: Result<UInt16, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}
