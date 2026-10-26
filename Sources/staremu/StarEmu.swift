import ArgumentParser
import Foundation
import StarEmuCore

@main
struct StarEmuCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "staremu",
        abstract: "Star printer emulator: mC-Print3, TSP100IIIW (unofficial).",
        version: "0.1.0",
        subcommands: [Serve.self, Parse.self, Render.self, Hexdump.self]
    )
}

struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Run the emulated printer headless (discovery, print and status ports) and store every job.")

    @Option(help: "Printer model: mcprint3, tsp100iiiw.")
    var model = DeviceProfile.mcPrint3.id

    @Option(help: "TCP port for print jobs.")
    var port: UInt16 = 9100

    @Option(help: "TCP status port (0 disables).")
    var statusPort: UInt16 = 9101

    @Flag(help: "Do not answer UDP 22222 discovery.")
    var noDiscovery = false

    @Option(help: "Directory for stored jobs (default: ~/Library/Application Support/StarEmu/jobs).")
    var out: String?

    @Option(help: "Also render each job to PNG in this directory.")
    var png: String?

    @Option(help: "Seconds without bytes after which a job without SDK framing is considered finished.")
    var idle: Double = 1.0

    @Option(help: "MAC address to advertise (default: a stable random one in identity.json).")
    var mac: String?

    @Option(help: "Simulated faults: cover-open, paper-empty, paper-near-end, offline (comma-separated).")
    var fault: String?

    @Flag(help: "Log discovery requests and status polls.")
    var verbose = false

    func run() async throws {
        let store = try JobStore(directory: out.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? JobStore.defaultDirectory)
        let identity = try mac.map { try DeviceIdentity(macString: $0).orThrow("Invalid --mac \($0)") } ?? DeviceIdentity.loadOrCreate()
        let profile = try DeviceProfile.named(model).orThrow("Unknown --model \(model) (use \(DeviceProfile.all.map(\.id).joined(separator: ", ")))")
        let config = EmulatorConfig(
            profile: profile, identity: identity, printPort: port, statusPort: statusPort == 0 ? .some(nil) : statusPort,
            discoveryPort: noDiscovery ? .some(nil) : nil, idleTimeout: .milliseconds(Int(idle * 1000)),
            faults: try parseFaults(fault)
        )
        let emulator = PrinterEmulator(config: config, store: store)
        guard case .started(let printPort, let statusPort, let discoveryPort) = try await emulator.start() else { return }

        let addresses = Interfaces.ipv4().map { "\($0.address) (\($0.name))" }.joined(separator: ", ")
        emit("\(profile.displayName) emulator (\(profile.modelName)) \(identity.macString) (SDK identifier \(identity.sdkIdentifier)) on \(addresses)")
        emit("print TCP \(printPort) · status TCP \(statusPort.map(String.init) ?? "off") · discovery UDP \(discoveryPort.map(String.init) ?? "off")")
        emit("faults: \(config.faults)")
        emit("jobs: \(store.directory.path)")

        let pngDirectory = png.map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let pngDirectory { try FileManager.default.createDirectory(at: pngDirectory, withIntermediateDirectories: true) }
        let jobPrinter = Task {
            for await job in emulator.jobs {
                var line = "\(job.receivedAt.ISO8601Format())  job  \(job.remote)  \(job.byteCount) bytes  \(store.rawURL(for: job).path)"
                if let pngDirectory, let data = try? store.data(for: job) {
                    let pages = Renderer.render(data)
                    let url = pngDirectory.appendingPathComponent("\(job.id.uuidString).png")
                    if let png = try? PNGExporter.png(PNGExporter.stacked(pages)) {
                        try? png.write(to: url)
                        line += "  -> \(url.path)"
                    }
                }
                emit(line)
            }
        }
        for await event in emulator.events {
            switch event {
            case .failed(let reason): emit("error: \(reason)", to: .standardError)
            case .discovery(let peer, let answered) where verbose: emit("discovery \(peer) \(answered ? "answered" : "ignored")")
            case .statusPoll(let peer) where verbose: emit("status poll \(peer)")
            case .stopped: jobPrinter.cancel(); return
            default: break
            }
        }
    }

    private func parseFaults(_ text: String?) throws -> FaultState {
        var faults = FaultState()
        for name in (text ?? "").split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !name.isEmpty {
            switch name {
            case "cover-open": faults.coverOpen = true
            case "paper-empty": faults.paperEmpty = true
            case "paper-near-end": faults.paperNearEnd = true
            case "offline": faults.offline = true
            default: throw ValidationError("Unknown fault \(name)")
            }
        }
        return faults
    }
}

extension Optional {
    func orThrow(_ message: String) throws -> Wrapped {
        guard let self else { throw ValidationError(message) }
        return self
    }
}

struct Hexdump: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print a hex dump of a captured job file.")

    @Argument(help: "Path to a .bin job file.")
    var file: String

    @Option(help: "Bytes per row.")
    var width: Int = 16

    func run() throws {
        emit(HexDump.format(try Data(contentsOf: URL(fileURLWithPath: file)), width: width))
    }
}

struct Parse: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print the StarPRNT commands in a job file, one per line.")

    @Argument(help: "Path to a .bin job file.")
    var file: String

    func run() throws {
        let commands = StarPRNTParser.parse(try Data(contentsOf: URL(fileURLWithPath: file)))
        for (index, command) in commands.enumerated() {
            emit(String(format: "%4d  ", index) + command.description)
        }
    }
}

struct Render: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Render a job file to PNG (all pages stacked, or one page).")

    @Argument(help: "Path to a .bin job file.")
    var file: String

    @Option(name: .shortAndLong, help: "Output PNG path.")
    var output: String

    @Option(help: "Render only this page (1-based).")
    var page: Int?

    func run() throws {
        let pages = Renderer.render(try Data(contentsOf: URL(fileURLWithPath: file)))
        guard !pages.isEmpty else { throw ValidationError("The job produced no paper.") }
        let bitmap: PaperBitmap
        if let page {
            guard pages.indices.contains(page - 1) else { throw ValidationError("Page \(page) of \(pages.count) does not exist.") }
            bitmap = pages[page - 1].bitmap
        } else {
            bitmap = PNGExporter.stacked(pages)
        }
        try PNGExporter.png(bitmap).write(to: URL(fileURLWithPath: output))
        let warnings = pages.flatMap(\.warnings)
        emit("\(pages.count) page(s), \(bitmap.width)x\(bitmap.height) dots -> \(output)")
        warnings.forEach { emit("warning: \($0)", to: .standardError) }
    }
}

/// Line-buffered output (plain `print` is block-buffered when piped).
private func emit(_ line: String, to handle: FileHandle = .standardOutput) {
    handle.write(Data((line + "\n").utf8))
}
