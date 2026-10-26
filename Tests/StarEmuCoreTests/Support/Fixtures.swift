import Foundation

enum Fixture {
    /// `Fixtures/<path>` from the test bundle, e.g. `Fixture.data("sdk/t-plain.bin")`.
    static func data(_ path: String) -> Data {
        let url = Bundle.module.resourceURL!.appendingPathComponent("Fixtures").appendingPathComponent(path)
        guard let data = try? Data(contentsOf: url) else { fatalError("missing fixture \(path)") }
        return data
    }

    static func sdk(_ name: String) -> Data { data("sdk/\(name).bin") }

    static let sdkNames = [
        "t-plain", "t-bold", "t-center", "t-right", "t-mag2x3", "t-invert", "t-underline", "t-fontb",
        "t-linespace", "t-feedline", "t-feed", "t-cut-partial", "t-cut-full", "t-utf8", "t-noeol",
        "image", "image-narrow", "qr", "barcode", "drawer", "receipt",
    ]
}

/// `hex("1b 45 41")` → bytes.
func hex(_ string: String) -> Data {
    let digits = string.filter(\.isHexDigit)
    return Data(stride(from: 0, to: digits.count, by: 2).map { i in
        let start = digits.index(digits.startIndex, offsetBy: i)
        return UInt8(digits[start...digits.index(after: start)], radix: 16)!
    })
}

/// Deterministic RNG for chunking and fuzz tests.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
