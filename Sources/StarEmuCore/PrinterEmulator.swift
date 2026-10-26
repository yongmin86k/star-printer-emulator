import Foundation
import os

public struct EmulatorConfig: Sendable, Equatable {
    public var profile: DeviceProfile
    public var identity: DeviceIdentity
    public var printPort: UInt16
    /// nil disables the TCP status port.
    public var statusPort: UInt16?
    /// nil disables discovery (the printer can still be used by IP).
    public var discoveryPort: UInt16?
    public var idleTimeout: Duration
    public var faults: FaultState

    public init(
        profile: DeviceProfile = .mcPrint3,
        identity: DeviceIdentity,
        printPort: UInt16? = nil,
        statusPort: UInt16?? = nil,
        discoveryPort: UInt16?? = nil,
        idleTimeout: Duration = .seconds(1),
        faults: FaultState = FaultState()
    ) {
        self.profile = profile
        self.identity = identity
        self.printPort = printPort ?? profile.printPort
        self.statusPort = statusPort ?? profile.statusPort
        self.discoveryPort = discoveryPort ?? profile.discoveryPort
        self.idleTimeout = idleTimeout
        self.faults = faults
    }
}

public enum EmulatorEvent: Sendable, Equatable {
    case started(printPort: UInt16, statusPort: UInt16?, discoveryPort: UInt16?)
    case discovery(peer: String, answered: Bool)
    case statusPoll(peer: String)
    case sessionOpened(SessionInfo)
    case sessionClosed(UUID)
    case failed(String)
    case stopped
}

/// The whole emulated printer: discovery (UDP 22222), print port (TCP 9100) with status replies and
/// document-based job splitting, and the status port (TCP 9101). See docs/protocol-notes.md.
public actor PrinterEmulator {
    public nonisolated let jobs: AsyncStream<Job>
    public nonisolated let events: AsyncStream<EmulatorEvent>
    public let config: EmulatorConfig

    private let eventSink: AsyncStream<EmulatorEvent>.Continuation
    private let assembler: JobAssembler
    private let log = Logger(subsystem: "dev.staremu", category: "Emulator")
    private var status: StatusEngine
    private var parsers: [UUID: StarPRNTParser] = [:]
    private var awaitingDocumentEnd: Set<UUID> = []
    private var statusPeers: [UUID: String] = [:]
    private var printServer: PrintServer?
    private var statusServer: PrintServer?
    private var discovery: DiscoveryResponder?
    private var tasks: [Task<Void, Never>] = []

    public init(config: EmulatorConfig, store: JobStore) {
        self.config = config
        status = StatusEngine(identity: config.identity, profile: config.profile)
        assembler = JobAssembler(store: store, idleTimeout: config.idleTimeout)
        jobs = assembler.jobs
        (events, eventSink) = AsyncStream.makeStream(of: EmulatorEvent.self)
        _ = status.setFaults(config.faults)
    }

    deinit {
        eventSink.finish()
    }

    public var faults: FaultState { status.faults }

    /// Starts all listeners. Ports of 0 pick ephemeral ports (tests); the result reports what was bound.
    @discardableResult
    public func start() async throws -> EmulatorEvent {
        do {
            let printPort = try await startPrintServer()
            let statusPort = try await startStatusServer()
            let discoveryPort = try startDiscovery()
            let started = EmulatorEvent.started(printPort: printPort, statusPort: statusPort, discoveryPort: discoveryPort)
            eventSink.yield(started)
            return started
        } catch {
            stop()
            throw error
        }
    }

    public func stop() {
        printServer?.stop()
        statusServer?.stop()
        discovery?.stop()
        tasks.forEach { $0.cancel() }
        (printServer, statusServer, discovery, tasks) = (nil, nil, nil, [])
        eventSink.yield(.stopped)
    }

    /// Changes simulated faults; sessions that enabled automatic status get an immediate push.
    public func setFaults(_ faults: FaultState) {
        for session in status.setFaults(faults) {
            printServer?.send(status.currentFrame, to: session)
        }
    }

    // MARK: - Startup

    private func startPrintServer() async throws -> UInt16 {
        let server = PrintServer()
        let port = try await server.start(port: config.printPort)
        printServer = server
        tasks.append(Task { for await event in server.events { await self.handlePrint(event, server: server) } })
        return port
    }

    private func startStatusServer() async throws -> UInt16? {
        guard let configured = config.statusPort else { return nil }
        let server = PrintServer()
        let port = try await server.start(port: configured)
        statusServer = server
        tasks.append(Task { for await event in server.events { self.handleStatusPort(event, server: server) } })
        return port
    }

    private func startDiscovery() throws -> UInt16? {
        guard let configured = config.discoveryPort else { return nil }
        let (profile, identity) = (config.profile, config.identity)
        let responder = DiscoveryResponder { peer in
            Interfaces.advertised(for: peer).map {
                DiscoveryProtocol.reply(DiscoveryProtocol.ReplyFields(profile: profile, identity: identity, interface: $0))
            }
        }
        let sink = eventSink
        responder.onRequest = { sink.yield(.discovery(peer: $0.peer, answered: $0.answered)) }
        let port = try responder.start(port: configured)
        discovery = responder
        return port
    }

    // MARK: - TCP 9100

    private func handlePrint(_ event: PrintServer.Event, server: PrintServer) async {
        switch event {
        case .opened(let info):
            parsers[info.id] = StarPRNTParser()
            await assembler.opened(info)
            eventSink.yield(.sessionOpened(info))
        case .received(let id, let data):
            await assembler.received(id, data)
            await respond(to: data, session: id, server: server)
        case .closed(let id):
            parsers[id] = nil
            awaitingDocumentEnd.remove(id)
            status.sessionClosed(id)
            await assembler.closed(id)
            eventSink.yield(.sessionClosed(id))
        case .failed(let reason):
            eventSink.yield(.failed(reason))
        case .listening, .stopped:
            break
        }
    }

    /// Answers status traffic and ends the job at the SDK's `ETB` + `ESC GS ETX 4` marker.
    private func respond(to data: Data, session id: UUID, server: PrintServer) async {
        guard var parser = parsers[id] else { return }
        let commands = parser.feed(data)
        parsers[id] = parser

        var reply = Data()
        var documentEnded = false
        for command in commands {
            reply += status.handle(command, session: id)
            switch command {
            case .etb: awaitingDocumentEnd.insert(id)
            case .documentControl(4) where awaitingDocumentEnd.contains(id):
                awaitingDocumentEnd.remove(id)
                documentEnded = true
            default: break
            }
        }
        if !reply.isEmpty { server.send(reply, to: id) }
        if documentEnded { await assembler.finishJob(id) }
    }

    // MARK: - TCP 9101

    /// One `0x32…` query → two ASB frames → close. Idle connections are closed after 5 s, like the printer.
    private func handleStatusPort(_ event: PrintServer.Event, server: PrintServer) {
        switch event {
        case .opened(let info):
            statusPeers[info.id] = info.remote
            tasks.append(Task {
                try? await Task.sleep(for: .seconds(5))
                server.close(info.id)
            })
        case .received(let id, let data):
            guard data.first == 0x32 else { return }
            server.send(status.statusPortReply, to: id, thenClose: true)
            eventSink.yield(.statusPoll(peer: statusPeers[id] ?? "?"))
        case .closed(let id):
            statusPeers[id] = nil
        case .failed(let reason):
            eventSink.yield(.failed(reason))
        case .listening, .stopped:
            break
        }
    }
}
