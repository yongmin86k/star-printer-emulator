import Foundation
import Observation
import StarEmuCore

/// User preferences, persisted in UserDefaults. Core types never read defaults themselves.
@MainActor
@Observable
final class AppSettings {
    private let defaults: UserDefaults

    var printPort: UInt16 { didSet { defaults.set(Int(printPort), forKey: Keys.printPort) } }
    var discoveryEnabled: Bool { didSet { defaults.set(discoveryEnabled, forKey: Keys.discovery) } }
    var macOverride: String { didSet { defaults.set(macOverride, forKey: Keys.mac) } }
    var idleTimeout: Double { didSet { defaults.set(idleTimeout, forKey: Keys.idle) } }
    var autoSelectNewJobs: Bool { didSet { defaults.set(autoSelectNewJobs, forKey: Keys.autoSelect) } }
    var keepLastJobs: Int { didSet { defaults.set(keepLastJobs, forKey: Keys.keepLast) } }
    var exportMode: JobExport.Mode { didSet { defaults.set(exportMode.rawValue, forKey: Keys.exportMode) } }
    var autoSaveEnabled: Bool { didSet { defaults.set(autoSaveEnabled, forKey: Keys.autoSave) } }
    var autoSaveBookmark: Data? { didSet { defaults.set(autoSaveBookmark, forKey: Keys.autoSaveBookmark) } }
    var showMenuBarIcon: Bool { didSet { defaults.set(showMenuBarIcon, forKey: Keys.menuBar) } }
    var modelID: String { didSet { defaults.set(modelID, forKey: Keys.model) } }

    enum Keys {
        static let printPort = "printPort", discovery = "discoveryEnabled", mac = "macOverride", idle = "idleTimeout"
        static let autoSelect = "autoSelectNewJobs", keepLast = "keepLastJobs", exportMode = "exportMode"
        static let autoSave = "autoSaveEnabled", autoSaveBookmark = "autoSaveBookmark", menuBar = "showMenuBarIcon"
        static let model = "model"
    }

    static let defaultValues: [String: Any] = [
        Keys.printPort: 9100, Keys.discovery: true, Keys.mac: "", Keys.idle: 1.0, Keys.autoSelect: true,
        Keys.keepLast: 200, Keys.exportMode: JobExport.Mode.stacked.rawValue, Keys.autoSave: false, Keys.menuBar: true,
        Keys.model: DeviceProfile.mcPrint3.id,
    ]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: Self.defaultValues)
        printPort = UInt16(clamping: defaults.integer(forKey: Keys.printPort))
        discoveryEnabled = defaults.bool(forKey: Keys.discovery)
        macOverride = defaults.string(forKey: Keys.mac) ?? ""
        idleTimeout = defaults.double(forKey: Keys.idle)
        autoSelectNewJobs = defaults.bool(forKey: Keys.autoSelect)
        keepLastJobs = defaults.integer(forKey: Keys.keepLast)
        exportMode = JobExport.Mode(rawValue: defaults.string(forKey: Keys.exportMode) ?? "") ?? .stacked
        autoSaveEnabled = defaults.bool(forKey: Keys.autoSave)
        autoSaveBookmark = defaults.data(forKey: Keys.autoSaveBookmark)
        showMenuBarIcon = defaults.bool(forKey: Keys.menuBar)
        modelID = defaults.string(forKey: Keys.model) ?? DeviceProfile.mcPrint3.id
    }

    /// The emulated model; unknown saved values fall back to mC-Print3.
    var profile: DeviceProfile {
        DeviceProfile.named(modelID) ?? .mcPrint3
    }

    /// Identity advertised to clients: the MAC override if valid, else the persisted random one.
    var identity: DeviceIdentity {
        DeviceIdentity(macString: macOverride) ?? DeviceIdentity.loadOrCreate()
    }

    /// The auto-save folder, resolved from its security-scoped bookmark.
    var autoSaveFolder: URL? {
        guard let autoSaveBookmark else { return nil }
        var stale = false
        return try? URL(resolvingBookmarkData: autoSaveBookmark, options: .withSecurityScope, bookmarkDataIsStale: &stale)
    }

    func setAutoSaveFolder(_ url: URL) {
        autoSaveBookmark = try? url.bookmarkData(options: .withSecurityScope)
    }
}
