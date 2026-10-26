import AppKit
import Foundation
import Observation
import StarEmuCore
import UniformTypeIdentifiers

@MainActor
@Observable
final class AppModel {
    enum ServerState: Equatable {
        case stopped
        case starting
        case running(printPort: UInt16, statusPort: UInt16?, discoveryPort: UInt16?)
        case failed(String)
    }

    let settings: AppSettings
    var state: ServerState = .stopped
    var jobs: [Job] = []
    var selection: Set<Job.ID> = []
    var addresses: [IPv4Interface] = Interfaces.ipv4()
    var faults = FaultState() {
        didSet { Task { [emulator, faults] in await emulator?.setFaults(faults) } }
    }
    /// Simulates an unplugged printer: listeners are stopped until turned off again.
    var unreachable = false {
        didSet { unreachable ? stop() : start() }
    }
    var lastDiscovery: (peer: String, at: Date)?
    var lastStatusPoll: Date?
    var lastError: String?
    var profile: DeviceProfile { settings.profile }
    private(set) var identity: DeviceIdentity

    private let store: JobStore?
    private var emulator: PrinterEmulator?
    private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var renderCache: [Job.ID: [Page]] = [:]

    init(settings: AppSettings) {
        self.settings = settings
        identity = settings.identity
        let store: JobStore?
        do {
            store = try JobStore()
        } catch {
            store = nil
            state = .failed("Job storage unavailable: \(error.localizedDescription)")
        }
        self.store = store
        jobs = (try? store?.loadAll()) ?? []
        selection = Set(jobs.prefix(1).map(\.id))
    }

    var isRunning: Bool {
        switch state {
        case .starting, .running: true
        case .stopped, .failed: false
        }
    }

    /// The job shown in the detail pane: only when exactly one is selected.
    var selectedJob: Job? {
        selection.count == 1 ? jobs.first { selection.contains($0.id) } : nil
    }

    /// Selected jobs in list order (newest first).
    var selectedJobs: [Job] {
        jobs.filter { selection.contains($0.id) }
    }

    // MARK: - Emulator lifecycle

    func start() {
        guard !isRunning, !unreachable, let store else { return }
        state = .starting
        addresses = Interfaces.ipv4()
        identity = settings.identity

        let config = EmulatorConfig(
            profile: profile, identity: identity, printPort: settings.printPort,
            discoveryPort: settings.discoveryEnabled ? nil : .some(nil),
            idleTimeout: .milliseconds(Int(settings.idleTimeout * 1000)), faults: faults
        )
        let emulator = PrinterEmulator(config: config, store: store)
        self.emulator = emulator

        tasks.append(Task {
            for await event in emulator.events { handle(event) }
        })
        tasks.append(Task {
            for await job in emulator.jobs { received(job) }
        })
        tasks.append(Task {
            do {
                try await emulator.start()
            } catch {
                state = .failed("\(error)")
            }
        })
    }

    func stop() {
        let emulator = self.emulator
        Task { await emulator?.stop() }
        self.emulator = nil
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        state = .stopped
    }

    /// Applies changed settings (port, discovery, MAC, idle timeout).
    func restart() {
        stop()
        start()
    }

    private func handle(_ event: EmulatorEvent) {
        switch event {
        case .started(let printPort, let statusPort, let discoveryPort):
            state = .running(printPort: printPort, statusPort: statusPort, discoveryPort: discoveryPort)
        case .discovery(let peer, true):
            lastDiscovery = (peer, Date())
        case .statusPoll:
            lastStatusPoll = Date()
        case .failed(let reason):
            state = .failed(reason)
        default:
            break
        }
    }

    private func received(_ job: Job) {
        jobs.insert(job, at: 0)
        if settings.autoSelectNewJobs { selection = [job.id] }
        autoSave(job)
        purgeOldJobs()
    }

    // MARK: - Jobs

    func data(for job: Job) -> Data {
        (try? store?.data(for: job)) ?? Data()
    }

    func commands(for job: Job) -> [Command] {
        StarPRNTParser.parse(data(for: job))
    }

    /// Rendered pages, cached per job (rendering is pure, jobs never change).
    func pages(for job: Job) -> [Page] {
        if let cached = renderCache[job.id] { return cached }
        let pages = Renderer.render(data(for: job))
        renderCache[job.id] = pages
        return pages
    }

    func delete(_ targets: [Job]) {
        let ids = Set(targets.map(\.id))
        targets.forEach { try? store?.delete($0) }
        jobs.removeAll { ids.contains($0.id) }
        ids.forEach { renderCache[$0] = nil }
        selection.subtract(ids)
        if selection.isEmpty { selection = Set(jobs.prefix(1).map(\.id)) }
    }

    func clearAll() {
        try? store?.deleteAll()
        jobs.removeAll()
        renderCache.removeAll()
        selection = []
    }

    /// Asks first, then deletes every job (menu ⇧⌘⌫ and the Jobs header button).
    func confirmClearAll() {
        confirmDelete(jobs)
    }

    /// Asks first, then deletes the jobs (Delete key, context menu, Clear All).
    func confirmDelete(_ targets: [Job]) {
        guard !targets.isEmpty else { return }
        let all = targets.count == jobs.count && targets.count > 1
        let alert = NSAlert()
        alert.messageText = all ? "Delete all \(targets.count) jobs?" : targets.count == 1 ? "Delete this job?" : "Delete \(targets.count) jobs?"
        alert.informativeText = "Raw job files are removed from disk. Saved PNGs are not affected."
        alert.addButton(withTitle: all ? "Delete All" : "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        all ? clearAll() : delete(targets)
    }

    func revealInFinder(_ job: Job) {
        guard let url = store?.rawURL(for: job) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func purgeOldJobs() {
        guard settings.keepLastJobs > 0, jobs.count > settings.keepLastJobs else { return }
        try? store?.purge(keepingLast: settings.keepLastJobs)
        let dropped = jobs.dropFirst(settings.keepLastJobs)
        dropped.forEach { renderCache[$0.id] = nil; selection.remove($0.id) }
        jobs.removeLast(dropped.count)
    }

    // MARK: - Import / export

    func importFiles(_ urls: [URL]) {
        guard let store else { return }
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                let job = try store.importJob(Data(contentsOf: url), named: url.lastPathComponent)
                jobs.insert(job, at: 0)
                selection = [job.id]
            } catch {
                lastError = "Import failed: \(error.localizedDescription)"
            }
        }
    }

    func presentImportPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose raw print job files (.bin) to render."
        guard panel.runModal() == .OK else { return }
        importFiles(panel.urls)
    }

    func pngFiles(for job: Job) -> [(name: String, data: Data)] {
        (try? JobExport.pngs(for: pages(for: job), baseName: JobExport.baseName(for: job), mode: settings.exportMode)) ?? []
    }

    func presentSavePanel(for job: Job) {
        let files = pngFiles(for: job)
        guard let first = files.first else { return lastError = "This job has nothing printed to save." }
        if files.count == 1 {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.png]
            panel.nameFieldStringValue = first.name
            guard panel.runModal() == .OK, let url = panel.url else { return }
            write { try first.data.write(to: url, options: .atomic) }
        } else {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "Save \(files.count) PNGs Here"
            guard panel.runModal() == .OK, let folder = panel.url else { return }
            write { try JobExport.write(files, to: folder) }
        }
    }

    func copyImage(of job: Job) {
        let pages = pages(for: job).filter { $0.bitmap.height > 0 }
        guard !pages.isEmpty, let png = try? PNGExporter.png(PNGExporter.stacked(pages)) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(png, forType: .png)
    }

    func chooseAutoSaveFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use for Auto-Save"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.setAutoSaveFolder(url)
        settings.autoSaveEnabled = true
    }

    private func autoSave(_ job: Job) {
        guard settings.autoSaveEnabled, let folder = settings.autoSaveFolder else { return }
        let accessing = folder.startAccessingSecurityScopedResource()
        defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
        write { try JobExport.write(pngFiles(for: job), to: folder) }
    }

    private func write(_ body: () throws -> Void) {
        do { try body() } catch { lastError = "Save failed: \(error.localizedDescription)" }
    }
}
