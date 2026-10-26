import Foundation

/// `hexdump -C`-style formatting shared by the CLI and the app.
public enum HexDump {
    /// One string per row: `offset  hex bytes  |ascii|`. Offsets are relative to the start of `data`.
    public static func lines(_ data: Data, width: Int = 16) -> [String] {
        guard width > 0 else { return [] }
        let bytes = [UInt8](data)
        return stride(from: 0, to: bytes.count, by: width).map { start in
            let row = bytes[start..<min(start + width, bytes.count)]
            let hex = row.map { String(format: "%02x", $0) }.joined(separator: " ")
            let paddedHex = hex.padding(toLength: width * 3 - 1, withPad: " ", startingAt: 0)
            return String(format: "%08x", start) + "  " + paddedHex + "  |" + ascii(row) + "|"
        }
    }

    public static func format(_ data: Data, width: Int = 16) -> String {
        lines(data, width: width).joined(separator: "\n")
    }

    private static func ascii(_ row: ArraySlice<UInt8>) -> String {
        String(row.map { (0x20...0x7E).contains($0) ? Character(Unicode.Scalar($0)) : "." })
    }
}
