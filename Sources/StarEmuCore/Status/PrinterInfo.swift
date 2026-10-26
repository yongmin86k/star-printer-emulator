import Foundation

/// Reply to `ESC GS ) I 01 00 31` (printer information) on the print port, as a real mC-Print3 sends it
/// (proxy capture, docs/protocol-notes.md §7). StarIO10 (2.9.1, from a POS app) sends the query right after
/// `ESC RS a 0` and waits ~8 s for this reply before giving up on the print.
///
/// Layout: 12-byte status frame, big-endian payload length, payload. The payload is the captured one with
/// only the identity fields replaced. UNVERIFIED: the meaning of the `A1:B 01 '7'` prefix, the `PrRk`/`PrRc`
/// values and the trailing `;` (no simple sum/XOR checksum matched, so it's sent as a constant).
public enum PrinterInfo {
    /// The only function we answer. The SDK also contains a `fn = 0x33` variant whose reply we haven't captured.
    public static let function: UInt8 = 0x31
    public static let request = Data([0x1B, 0x1D, 0x29, 0x49, 0x01, 0x00, function])

    public static func reply(identity: DeviceIdentity, status: Data) -> Data {
        let serial = serial(for: identity)
        let fields = [
            "PrHwV=1.0", "PrErL=0000000000", "PrSrN=\(serial)", "LaNmA=\(identity.sdkIdentifier)", "UsSrN=\(serial)",
            "PrBoV=3.82\0\0\0", "PrFc1=01", "PrFc2=\0\0", "PrFc3=\0\0", "PrPcS=\(serial)",
            "PrCsN=\(serial.suffix(13))" + String(repeating: "\0", count: 17),
            "PrRk1=01", "PrRk2=01", "PrRk3=01", "PrRk4=01", "PrRk5=01",
            "PrRc1=f26c", "PrRc2=bcca", "PrRc3=9b3d", "PrRc4=2122", "PrRc5=7b7e",
            "PrFnV=2.0\n\0;",
        ]
        let payload = Data("A1:B\u{01}7".utf8) + request + Data(fields.joined(separator: ",").utf8)
        return status + Data([UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)]) + payload
    }

    /// 16 decimal digits derived from the MAC: stable per installation and never a real printer's serial.
    static func serial(for identity: DeviceIdentity) -> String {
        let n = identity.mac.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        return String(format: "%016llu", n)
    }
}
