import Foundation

/// Star discovery on UDP 22222 (docs/protocol-notes.md §1).
public enum DiscoveryProtocol {
    public static let magic = Data("STR_BCAST".utf8)
    public static let replyLength = 302

    /// Answer only the 28-byte `RQ1.*` query; StarIO10 also sends `RQ4.*`, which a reply is not needed for.
    public static func shouldAnswer(_ request: Data) -> Bool {
        let bytes = [UInt8](request)
        guard bytes.count >= 28, bytes.starts(with: magic) else { return false }
        guard bytes[9..<16].allSatisfy({ $0 == 0 }) else { return false }
        guard bytes[0x18] == 0x00, bytes[0x19] == 0x1C else { return false }
        return bytes[0x10..<0x14].elementsEqual("RQ1.".utf8)
    }

    public struct ReplyFields: Sendable, Equatable {
        public var shortName: String
        public var modelName: String
        public var firmware: String
        public var mac: [UInt8]
        public var ip: String
        public var netmask: String
        public var gateway: String

        public init(shortName: String, modelName: String, firmware: String, mac: [UInt8], ip: String, netmask: String, gateway: String) {
            self.shortName = shortName
            self.modelName = modelName
            self.firmware = firmware
            self.mac = mac
            self.ip = ip
            self.netmask = netmask
            self.gateway = gateway
        }

        public init(profile: DeviceProfile, identity: DeviceIdentity, interface: IPv4Interface) {
            self.init(
                shortName: profile.shortName, modelName: profile.modelName, firmware: profile.firmware, mac: identity.mac,
                ip: interface.address, netmask: interface.netmask, gateway: interface.assumedGateway
            )
        }
    }

    /// 302-byte `RS1.0.1` reply. Matches a real mC-Print3 and a real TSP100IIIW byte for byte apart from the patched
    /// identity fields (protocol-notes §1, §8).
    public static func reply(_ f: ReplyFields) -> Data {
        var r = [UInt8](repeating: 0, count: replyLength)
        func put(_ offset: Int, _ bytes: [UInt8]) { r.replaceSubrange(offset..<offset + bytes.count, with: bytes) }
        func put(_ offset: Int, _ text: String, size: Int) { put(offset, Array(Array(text.utf8).prefix(size))) }

        put(0x00, "STR_BCAST", size: 16)
        put(0x10, "RS1.0.1", size: 8)
        put(0x18, [0x01, 0x2E, 0x00, 0x22, 0x00, 0x74, 0x00, 0x8A, 0x01, 0x2C])
        put(0x23, [UInt8(ascii: "R")])
        put(0x24, f.shortName, size: 15)
        put(0x34, f.firmware, size: 8)
        put(0x3C, f.firmware, size: 8)
        put(0x44, [0x20])
        put(0x4C, [0x31, 0x00])
        put(0x4E, f.mac)
        put(0x58, IPv4.bytes(f.ip))
        put(0x5C, "DHCP", size: 4)
        put(0x6C, IPv4.bytes(f.netmask))
        put(0x70, IPv4.bytes(f.gateway))
        put(0x74, [0x00, 0x16, 0x31, 0x00])
        put(0x84, [0x30, 0x00, 0x31, 0x00, 0x31, 0x00, 0x00, 0xA2])
        put(0x8C, "Star", size: 4)
        put(0xAC, "STAR", size: 4)
        put(0xCC, f.modelName, size: 64)
        put(0x10C, "PRINTER", size: 7)
        put(0x12C, [0x00, 0x02])
        return Data(r)
    }
}
