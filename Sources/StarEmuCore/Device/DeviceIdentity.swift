import Foundation

/// The per-installation identity a client sees. StarIO10 uses the MAC as the LAN printer
/// identifier, so it must stay the same across launches (docs/protocol-notes.md).
public struct DeviceIdentity: Sendable, Codable, Equatable {
    /// 6 bytes. Generated values are locally administered (`02:…`) so they can't clash with real Star MACs.
    public var mac: [UInt8]

    public init(mac: [UInt8]) {
        precondition(mac.count == 6, "MAC must be 6 bytes")
        self.mac = mac
    }

    public static func random() -> DeviceIdentity {
        var bytes = (0..<6).map { _ in UInt8.random(in: 0...255) }
        bytes[0] = (bytes[0] & 0xFC) | 0x02   // unicast, locally administered
        return DeviceIdentity(mac: bytes)
    }

    /// "02:53:54:41:52:01"
    public var macString: String {
        mac.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    /// What StarIO10 reports as the printer identifier: "025354415201".
    public var sdkIdentifier: String {
        mac.map { String(format: "%02X", $0) }.joined()
    }

    public init?(macString: String) {
        let parts = macString.split(whereSeparator: { $0 == ":" || $0 == "-" }).compactMap { UInt8($0, radix: 16) }
        guard parts.count == 6 else { return nil }
        self.init(mac: parts)
    }

    public static var defaultURL: URL {
        JobStore.defaultDirectory.deletingLastPathComponent().appendingPathComponent("identity.json")
    }

    /// Loads the saved identity, or creates and saves a new random one.
    public static func loadOrCreate(at url: URL = defaultURL) -> DeviceIdentity {
        if let data = try? Data(contentsOf: url), let identity = try? JSONDecoder().decode(DeviceIdentity.self, from: data) {
            return identity
        }
        let identity = DeviceIdentity.random()
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(identity).write(to: url, options: .atomic)
        return identity
    }
}
