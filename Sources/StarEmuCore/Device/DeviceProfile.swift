/// Static description of an emulated printer model.
public struct DeviceProfile: Sendable, Equatable, Identifiable {
    /// Stable key for settings and the CLI (`--model`).
    public var id: String
    /// Full model string in the discovery reply. StarIO10 derives model and emulation from it (docs/protocol-notes.md).
    public var modelName: String
    public var displayName: String
    public var dotsPerLine: Int
    public var dpi: Int
    public var printPort: UInt16
    /// Status poll port (SDK-verified: `0x32` query → 2 × ASB, see docs/protocol-notes.md §2).
    public var statusPort: UInt16?
    /// Short device name in the discovery reply (SDK `reserved["name"]`).
    public var shortName: String
    /// Main and boot firmware version in the discovery reply.
    public var firmware: String
    /// Real TSP100IIIW: frames only in answer to `ESC ACK SOH` (none after ETB or `ESC RS a 1`). §8.
    public var answersOnlyStatusRequests: Bool
    /// Status 1 bits a real printer always reports. TSP100IIIW: bit 2 (SDK `drawer = true`). §8.
    public var idleStatus1: UInt8
    /// Real TSP100IIIW: with the cover open the paper sensor reads empty, so paper empty is reported too. §8.
    public var coverOpenHidesPaper: Bool
    public var discoveryPort: UInt16 { 22222 }

    public var fontACell: (w: Int, h: Int) { (12, 24) }
    public var fontBCell: (w: Int, h: Int) { (9, 24) }

    public static let mcPrint3 = DeviceProfile(
        id: "mcprint3",
        modelName: "MCP31L (STR-001)",
        displayName: "mC-Print3",
        dotsPerLine: 576,
        dpi: 203,
        printPort: 9100,
        statusPort: 9101,
        shortName: "MCP31L",
        firmware: "V1.0",
        answersOnlyStatusRequests: false,
        idleStatus1: 0x00,
        coverOpenHidesPaper: false
    )

    /// StarGraphic-only: the SDK sends raster images and drops text (docs/protocol-notes.md §8).
    /// The model string is what the real unit reports; the product is sold as TSP100IIIW.
    public static let tsp100IIIW = DeviceProfile(
        id: "tsp100iiiw",
        modelName: "TSP143IIIW (STR_T-001)",
        displayName: "TSP100IIIW",
        dotsPerLine: 576,
        dpi: 203,
        printPort: 9100,
        statusPort: 9101,
        shortName: "TSP100LAN",
        firmware: "V2.4",
        answersOnlyStatusRequests: true,
        idleStatus1: 0x04,
        coverOpenHidesPaper: true
    )

    public static let all = [mcPrint3, tsp100IIIW]

    public static func named(_ id: String) -> DeviceProfile? {
        all.first { $0.id == id.lowercased() }
    }
}
