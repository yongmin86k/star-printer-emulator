import Foundation

public enum Alignment: UInt8, Sendable, Equatable {
    case left = 0, center = 1, right = 2
}

/// `ESC d n` values. SDK sends `.fullAfterFeed` for `actionCut(.full)`, `.partialAfterFeed` for `.partial`.
public enum CutType: UInt8, Sendable, Equatable, Codable {
    case full = 0, partial = 1, fullAfterFeed = 2, partialAfterFeed = 3

    public var isPartial: Bool { self == .partial || self == .partialAfterFeed }
    public var feedsFirst: Bool { self == .fullAfterFeed || self == .partialAfterFeed }
}

public enum PrinterFont: UInt8, Sendable, Equatable {
    case a = 0, b = 1
}

/// `ESC GS S` band: `widthBytes × height` bytes, MSB = leftmost dot, 1 = black.
public struct RasterBand: Sendable, Equatable {
    public let widthBytes: Int
    public let height: Int
    public let bits: Data

    public init(widthBytes: Int, height: Int, bits: Data) {
        self.widthBytes = widthBytes
        self.height = height
        self.bits = bits
    }
}

/// `ESC b n1 n2 n3 n4 d… RS`.
public struct BarcodeSpec: Sendable, Equatable {
    public let symbology: UInt8
    public let hri: UInt8
    public let mode: UInt8
    public let heightDots: Int
    public let data: Data
}

/// One decoded StarPRNT command. Byte sequences are documented in docs/starprnt-command-map.md.
public enum Command: Sendable, Equatable {
    // Text and layout
    case text(Data)
    case lineFeed
    case carriageReturn
    case horizontalTab
    case initialize
    case bold(Bool)
    case alignment(Alignment)
    case magnify(width: Int, height: Int)
    case invert(Bool)
    case underline(Int)
    case font(PrinterFont)
    case linePitch(dots: Int)
    case feedLines(Int)
    case feedDots(Int)
    case cut(CutType)
    case codePage(UInt8)
    case intlCharset(UInt8)
    case tabStops([UInt8])
    case charSpacing(Int)

    // Graphics
    case raster(RasterBand)
    case rasterMode(Bool)              // ESC * r A / ESC * r B
    case rasterLine(Data)              // raster-mode `b nL nH d…`
    case rasterModeSetting(UInt8, String)  // raster-mode `ESC * r x … NUL`
    case formFeed(UInt8)               // `ESC FF n`: raster-mode page end (n = EM: EOT mode, NUL: FF mode)
    case qrModel(Int)
    case qrLevel(Int)
    case qrCellSize(Int)
    case qrData(Data)
    case qrPrint
    case barcode(BarcodeSpec)

    // Peripherals
    case drawerPulse(on: UInt8, off: UInt8)
    case drawerKick(channel: Int)

    // Session / status — consumed by the status engine, never rendered
    case statusRequest                 // ESC ACK SOH
    case asb(enabled: Bool)            // ESC RS a n
    case clearETB                      // ESC RS E n
    case etb
    case documentControl(UInt8)        // ESC GS ETX s n1 n2 (3 = start, 4 = end)
    case printerInfoRequest(UInt8)     // ESC GS ) I pL pH fn …
    case nul

    // Recognised, no effect on output
    case ignored(String, Data)
    // Diagnostics
    case unknown(Data)
    case malformed(String, Data)

    /// True for commands that put something on paper, kick a drawer, or are unrecognised
    /// (unrecognised bytes are kept so they show up for debugging).
    public var producesOutput: Bool {
        switch self {
        case .text, .lineFeed, .horizontalTab, .feedLines, .feedDots, .cut, .raster, .rasterLine, .formFeed,
             .qrPrint, .barcode, .drawerKick, .unknown, .malformed:
            true
        default:
            false
        }
    }

    public var isSessionControl: Bool {
        switch self {
        case .statusRequest, .asb, .clearETB, .etb, .documentControl, .printerInfoRequest, .nul: true
        default: false
        }
    }
}

extension Command: CustomStringConvertible {
    public var description: String {
        switch self {
        case .text(let d): "text(\(String(decoding: d, as: UTF8.self).debugDescription))"
        case .raster(let b): "raster(\(b.widthBytes * 8)x\(b.height))"
        case .rasterLine(let d): "rasterLine(\(d.count) bytes)"
        case .qrData(let d): "qrData(\(String(decoding: d, as: UTF8.self).debugDescription))"
        case .barcode(let b): "barcode(type=\(b.symbology) hri=\(b.hri) mode=\(b.mode) h=\(b.heightDots) \(String(decoding: b.data, as: UTF8.self).debugDescription))"
        case .ignored(let name, let d): "ignored(\(name) \(d.hexString))"
        case .unknown(let d): "unknown(\(d.hexString))"
        case .malformed(let why, let d): "malformed(\(why), \(d.count) bytes)"
        case .lineFeed: "lineFeed"
        case .carriageReturn: "carriageReturn"
        case .horizontalTab: "horizontalTab"
        case .initialize: "initialize"
        case .bold(let on): "bold(\(on))"
        case .alignment(let a): "alignment(\(a))"
        case .magnify(let w, let h): "magnify(w=\(w) h=\(h))"
        case .invert(let on): "invert(\(on))"
        case .underline(let n): "underline(\(n))"
        case .font(let f): "font(\(f))"
        case .linePitch(let dots): "linePitch(\(dots) dots)"
        case .feedLines(let n): "feedLines(\(n))"
        case .feedDots(let n): "feedDots(\(n))"
        case .cut(let type): "cut(\(type))"
        case .codePage(let n): "codePage(0x\(String(n, radix: 16)))"
        case .intlCharset(let n): "intlCharset(\(n))"
        case .tabStops(let stops): "tabStops(\(stops))"
        case .charSpacing(let n): "charSpacing(\(n))"
        case .rasterMode(let on): "rasterMode(\(on))"
        case .formFeed(let n): "formFeed(\(n))"
        case .rasterModeSetting(let letter, let value): "rasterModeSetting(\(Character(Unicode.Scalar(letter))) \(value.debugDescription))"
        case .qrModel(let n): "qrModel(\(n))"
        case .qrLevel(let n): "qrLevel(\(n))"
        case .qrCellSize(let n): "qrCellSize(\(n))"
        case .qrPrint: "qrPrint"
        case .drawerPulse(let on, let off): "drawerPulse(on=\(on) off=\(off))"
        case .drawerKick(let channel): "drawerKick(\(channel))"
        case .statusRequest: "statusRequest"
        case .printerInfoRequest(let fn): String(format: "printerInfoRequest(fn=0x%02X)", fn)
        case .asb(let enabled): "asb(enabled=\(enabled))"
        case .clearETB: "clearETB"
        case .etb: "etb"
        case .documentControl(let s): "documentControl(\(s == 3 ? "start" : s == 4 ? "end" : "\(s)"))"
        case .nul: "nul"
        }
    }
}

extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined(separator: " ") }
}
