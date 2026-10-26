import Foundation

/// Streaming StarPRNT decoder: feed chunks as they arrive, get back every command that is complete.
/// Never throws and never stalls on bad input — unknown bytes become `.unknown`, oversized or
/// truncated payloads become `.malformed`. Byte layouts: docs/starprnt-command-map.md.
public struct StarPRNTParser: Sendable {
    public static let maxPayload = 8 * 1024 * 1024

    private var pending: [UInt8] = []
    private var rasterMode = false

    public init() {}

    /// Convenience for a complete buffer.
    public static func parse(_ data: Data) -> [Command] {
        var parser = StarPRNTParser()
        return parser.feed(data) + parser.finish()
    }

    public mutating func feed(_ chunk: Data) -> [Command] {
        pending.append(contentsOf: chunk)
        return drain(atEnd: false)
    }

    /// End of input: an incomplete trailing command is reported as `.malformed`.
    public mutating func finish() -> [Command] {
        drain(atEnd: true)
    }

    // MARK: - Driver

    private enum Step {
        case command(Command, length: Int)
        case needMore
    }

    private mutating func drain(atEnd: Bool) -> [Command] {
        var commands: [Command] = []
        var i = 0
        while i < pending.count {
            guard case .command(let command, let length) = decode(at: i) else {
                if atEnd {
                    commands.append(.malformed("truncated", Data(pending[i...])))
                    i = pending.count
                }
                break
            }
            if case .rasterMode(let on) = command { rasterMode = on }
            commands.append(command)
            i += length
        }
        pending.removeFirst(i)
        return commands
    }

    private func decode(at i: Int) -> Step {
        let byte = pending[i]
        if rasterMode, byte == 0x62 { return rasterLine(at: i) }           // raster-mode 'b'
        if rasterMode, byte >= 0x20 { return .command(.unknown(Data([byte])), length: 1) }
        if byte >= 0x20 { return textRun(at: i) }
        if byte == 0x1B { return escape(at: i) }
        return .command(Self.singleByte[byte] ?? .unknown(Data([byte])), length: 1)
    }

    // MARK: - Tables (fixed-length commands)

    private typealias Maker = @Sendable ([UInt8]) -> Command
    private typealias Fixed = (params: Int, make: Maker)

    private static let singleByte: [UInt8: Command] = [
        0x00: .nul,
        0x07: .drawerKick(channel: 1),     // BEL
        0x09: .horizontalTab,
        0x0A: .lineFeed,
        0x0D: .carriageReturn,
        0x17: .etb,
        0x1A: .drawerKick(channel: 2),     // SUB (UNVERIFIED)
    ]

    /// `ESC x params…`
    private static let escFixed: [UInt8: Fixed] = [
        0x40: (0, { _ in .initialize }),                                        // @
        0x45: (0, { _ in .bold(true) }),                                        // E
        0x46: (0, { _ in .bold(false) }),                                       // F
        0x34: (0, { _ in .invert(true) }),                                      // 4
        0x35: (0, { _ in .invert(false) }),                                     // 5
        0x30: (0, { _ in .linePitch(dots: 24) }),                               // 0 (UNVERIFIED)
        0x69: (2, { p in .magnify(width: magnification(p[1]), height: magnification(p[0])) }), // i h-1 w-1
        0x2D: (1, { p in .underline(Int(p[0] & 0x03)) }),                       // -
        0x7A: (1, { p in .linePitch(dots: p[0] & 0x01 == 0 ? 24 : 32) }),       // z
        0x61: (1, { p in .feedLines(Int(p[0])) }),                              // a
        0x49: (1, { p in .feedDots(Int(p[0])) }),                               // I
        0x4A: (1, { p in .feedDots(Int(p[0]) * 2) }),                           // J (UNVERIFIED: n/4 mm)
        0x64: (1, { p in .cut(CutType(rawValue: p[0] & 0x03) ?? .partial) }),  // d
        0x52: (1, { p in .intlCharset(p[0]) }),                                 // R
        0x20: (1, { p in .charSpacing(Int(p[0])) }),                            // SP
        0x73: (2, { p in .ignored("ESC s", Data(p)) }),                         // s
        0x74: (2, { p in .ignored("ESC t", Data(p)) }),                         // t
        0x07: (2, { p in .drawerPulse(on: p[0], off: p[1]) }),                  // BEL
        0x0C: (1, { p in .formFeed(p[0]) }),                                    // FF (raster mode)
    ]

    /// `ESC GS x params…`
    private static let escGSFixed: [UInt8: Fixed] = [
        0x61: (1, { p in .alignment(Alignment(rawValue: p[0] & 0x03) ?? .left) }),   // a
        0x74: (1, { p in .codePage(p[0]) }),                                         // t
        0x03: (3, { p in .documentControl(p[0]) }),                                  // ETX s n1 n2
    ]

    /// `ESC RS x params…`
    private static let escRSFixed: [UInt8: Fixed] = [
        0x61: (1, { p in .asb(enabled: p[0] != 0) }),                                // a
        0x45: (1, { _ in .clearETB }),                                               // E
        0x46: (1, { p in .font(PrinterFont(rawValue: p[0] & 0x01) ?? .a) }),        // F
        0x41: (1, { p in .ignored("ESC RS A", Data(p)) }),                           // A
    ]

    private static func magnification(_ n: UInt8) -> Int {
        Int(min(n & 0x0F, 5)) + 1
    }

    // MARK: - Decoders

    private func textRun(at i: Int) -> Step {
        var end = i
        while end < pending.count, pending[end] >= 0x20 { end += 1 }
        return .command(.text(Data(pending[i..<end])), length: end - i)
    }

    private func escape(at i: Int) -> Step {
        guard i + 1 < pending.count else { return .needMore }
        let second = pending[i + 1]
        switch second {
        case 0x1D: return prefixed(at: i, prefixLength: 3, table: Self.escGSFixed, variable: escGS)
        case 0x1E: return prefixed(at: i, prefixLength: 3, table: Self.escRSFixed, variable: nil)
        case 0x06: return statusRequest(at: i)
        case 0x2A: return rasterModeCommand(at: i)
        case 0x44: return tabStops(at: i)
        case 0x62: return barcode(at: i)
        default: return fixed(at: i, prefixLength: 2, spec: Self.escFixed[second])
        }
    }

    /// Commands addressed by a 3-byte prefix (ESC GS x / ESC RS x).
    private func prefixed(at i: Int, prefixLength: Int, table: [UInt8: Fixed], variable: ((Int) -> Step?)?) -> Step {
        guard i + prefixLength <= pending.count else { return .needMore }
        if let step = variable?(i) { return step }
        return fixed(at: i, prefixLength: prefixLength, spec: table[pending[i + prefixLength - 1]])
    }

    private func fixed(at i: Int, prefixLength: Int, spec: Fixed?) -> Step {
        guard let spec else {
            return .command(.unknown(Data(pending[i..<i + prefixLength])), length: prefixLength)
        }
        let total = prefixLength + spec.params
        guard i + total <= pending.count else { return .needMore }
        return .command(spec.make(Array(pending[i + prefixLength..<i + total])), length: total)
    }

    /// Variable-length `ESC GS` commands; nil = not one of these.
    private func escGS(at i: Int) -> Step? {
        switch pending[i + 2] {
        case 0x53: return rasterBand(at: i)       // S
        case 0x79: return qrCode(at: i)           // y
        case 0x29: return escGSParen(at: i)
        default: return nil
        }
    }

    private func statusRequest(at i: Int) -> Step {
        guard i + 3 <= pending.count else { return .needMore }
        let command: Command = pending[i + 2] == 0x01 ? .statusRequest : .unknown(Data(pending[i..<i + 3]))
        return .command(command, length: 3)
    }

    /// `ESC GS S m xL xH yL yH n d…` — x = bytes per row, y = rows.
    private func rasterBand(at i: Int) -> Step {
        guard i + 9 <= pending.count else { return .needMore }
        let widthBytes = word(at: i + 4)
        let height = word(at: i + 6)
        let size = widthBytes * height
        guard size <= Self.maxPayload else {
            return .command(.malformed("raster \(widthBytes)x\(height) too large", Data(pending[i..<i + 9])), length: 9)
        }
        guard i + 9 + size <= pending.count else { return .needMore }
        let band = RasterBand(widthBytes: widthBytes, height: height, bits: Data(pending[i + 9..<i + 9 + size]))
        return .command(.raster(band), length: 9 + size)
    }

    /// `ESC GS y S fn n` settings, `ESC GS y D 1 m nL nH d…` data, `ESC GS y P` print.
    private func qrCode(at i: Int) -> Step {
        guard i + 4 <= pending.count else { return .needMore }
        switch pending[i + 3] {
        case 0x50:  // P
            return .command(.qrPrint, length: 4)
        case 0x53:  // S
            guard i + 6 <= pending.count else { return .needMore }
            let n = Int(pending[i + 5])
            let command: Command = switch pending[i + 4] {
            case 0x30: .qrModel(n)
            case 0x31: .qrLevel(n)
            case 0x32: .qrCellSize(n)
            default: .ignored("ESC GS y S", Data(pending[i + 4..<i + 6]))
            }
            return .command(command, length: 6)
        case 0x44:  // D
            guard i + 8 <= pending.count else { return .needMore }
            let size = word(at: i + 6)
            guard i + 8 + size <= pending.count else { return .needMore }
            return .command(.qrData(Data(pending[i + 8..<i + 8 + size])), length: 8 + size)
        default:
            return .command(.unknown(Data(pending[i..<i + 4])), length: 4)
        }
    }

    /// Generic `header + n bytes` where n is a 16-bit LE value inside the header.
    private func lengthPrefixed(at i: Int, headerLength: Int, lengthAt offset: Int, name: String) -> Step {
        guard i + headerLength <= pending.count else { return .needMore }
        let size = word(at: i + offset)
        guard i + headerLength + size <= pending.count else { return .needMore }
        return .command(.ignored(name, Data(pending[i + 3..<i + headerLength + size])), length: headerLength + size)
    }

    /// `ESC GS ) fn pL pH d…`. `I` (printer information, d = function byte) needs a reply; the rest are ignored.
    private func escGSParen(at i: Int) -> Step {
        let step = lengthPrefixed(at: i, headerLength: 6, lengthAt: 4, name: "ESC GS )")
        guard case .command(.ignored(_, let body), let length) = step, body.first == 0x49, body.count > 3 else { return step }
        return .command(.printerInfoRequest(body[body.startIndex + 3]), length: length)
    }

    /// `ESC D n1 … nk NUL`
    private func tabStops(at i: Int) -> Step {
        guard let end = terminator(0x00, from: i + 2, limit: 64) else { return needMoreOrMalformed(at: i, limit: 64) }
        return .command(.tabStops(Array(pending[i + 2..<end])), length: end + 1 - i)
    }

    /// `ESC b n1 n2 n3 n4 d… RS`
    private func barcode(at i: Int) -> Step {
        guard i + 6 <= pending.count else { return .needMore }
        guard let end = terminator(0x1E, from: i + 6, limit: 256) else { return needMoreOrMalformed(at: i, limit: 256) }
        let spec = BarcodeSpec(
            symbology: pending[i + 2], hri: pending[i + 3], mode: pending[i + 4],
            heightDots: Int(pending[i + 5]), data: Data(pending[i + 6..<end])
        )
        return .command(.barcode(spec), length: end + 1 - i)
    }

    /// `ESC * r A` / `ESC * r B` / `ESC * r C`, or `ESC * r x value NUL`.
    private func rasterModeCommand(at i: Int) -> Step {
        guard i + 4 <= pending.count else { return .needMore }
        guard pending[i + 2] == 0x72 else { return .command(.unknown(Data(pending[i..<i + 2])), length: 2) }
        let letter = pending[i + 3]
        switch letter {
        case 0x41: return .command(.rasterMode(true), length: 4)
        case 0x42: return .command(.rasterMode(false), length: 4)
        case 0x43: return .command(.ignored("ESC * r C", Data()), length: 4)
        default:
            guard let end = terminator(0x00, from: i + 4, limit: 32) else { return needMoreOrMalformed(at: i, limit: 32) }
            let value = String(decoding: pending[i + 4..<end], as: UTF8.self)
            return .command(.rasterModeSetting(letter, value), length: end + 1 - i)
        }
    }

    /// Raster mode `b nL nH d…`
    private func rasterLine(at i: Int) -> Step {
        guard i + 3 <= pending.count else { return .needMore }
        let size = word(at: i + 1)
        guard i + 3 + size <= pending.count else { return .needMore }
        return .command(.rasterLine(Data(pending[i + 3..<i + 3 + size])), length: 3 + size)
    }

    // MARK: - Helpers

    private func word(at i: Int) -> Int {
        Int(pending[i]) | Int(pending[i + 1]) << 8
    }

    private func terminator(_ value: UInt8, from start: Int, limit: Int) -> Int? {
        let end = min(pending.count, start + limit)
        guard start <= end else { return nil }
        return pending[start..<end].firstIndex(of: value)
    }

    /// Terminator not found: wait if the limit isn't reached yet, otherwise give up on this ESC.
    private func needMoreOrMalformed(at i: Int, limit: Int) -> Step {
        guard pending.count - i >= limit + 2 else { return .needMore }
        return .command(.malformed("unterminated", Data(pending[i..<i + 2])), length: 2)
    }
}
