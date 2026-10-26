import Foundation

public struct RenderOptions: Sendable, Equatable {
    public var dotsPerLine: Int
    /// Paper fed before an "after feed" cut (`ESC d 2/3`). UNVERIFIED: ~3 mm head-to-cutter distance.
    public var cutFeedDots: Int

    public init(dotsPerLine: Int = DeviceProfile.mcPrint3.dotsPerLine, cutFeedDots: Int = 24) {
        self.dotsPerLine = dotsPerLine
        self.cutFeedDots = cutFeedDots
    }
}

public enum PageEvent: Sendable, Equatable {
    case drawerKick(channel: Int, row: Int)
    case warning(String, row: Int)
}

/// One piece of paper between cuts.
public struct Page: Sendable, Equatable {
    public var bitmap: PaperBitmap
    /// How the page was ended; nil when the job ended without a cut.
    public var cut: CutType?
    public var events: [PageEvent]

    public var warnings: [String] {
        events.compactMap { if case .warning(let message, _) = $0 { message } else { nil } }
    }

    public var drawerKicks: [Int] {
        events.compactMap { if case .drawerKick(let channel, _) = $0 { channel } else { nil } }
    }
}

extension Array where Element == Page {
    /// True for a job that put nothing on paper and did nothing else, e.g. text sent to a StarGraphic printer.
    public var isBlank: Bool {
        allSatisfy { $0.bitmap.inkCount == 0 && $0.drawerKicks.isEmpty }
    }

    /// True for a job that only kicks the cash drawer and puts nothing on paper.
    public var isDrawerOnly: Bool {
        allSatisfy { $0.bitmap.height == 0 } && contains { !$0.drawerKicks.isEmpty }
    }
}

/// Turns parsed commands into paper. Text layout follows the device's fixed cells:
/// Font A 12×24, Font B 9×24, 576 dots per line, magnification by integer scaling.
public struct Renderer {
    struct TextStyle: Equatable {
        var font: PrinterFont = .a
        var bold = false
        var invert = false
        var underline = 0
        var magWidth = 1
        var magHeight = 1

        var cellWidth: Int { font == .a ? 12 : 9 }
        static let cellHeight = 24
    }

    struct Glyph {
        let character: Character
        let style: TextStyle
        let width: Int
    }

    let options: RenderOptions
    var style = TextStyle()
    var alignment: Alignment = .left
    var linePitch = 32
    var charSpacing = 0
    var codePage: UInt8 = 0x80
    var tabStops: [UInt8] = []
    var line: [(byte: UInt8, style: TextStyle)] = []
    var qr = QRState()
    var rasterPageCut: CutType = .partialAfterFeed

    var paper: PaperBitmap
    var cursor = 0
    var events: [PageEvent] = []
    var pages: [Page] = []

    public init(options: RenderOptions = RenderOptions()) {
        self.options = options
        paper = PaperBitmap(width: options.dotsPerLine)
    }

    public static func render(_ commands: [Command], options: RenderOptions = RenderOptions()) -> [Page] {
        var renderer = Renderer(options: options)
        commands.forEach { renderer.apply($0) }
        return renderer.finish()
    }

    public static func render(_ data: Data, options: RenderOptions = RenderOptions()) -> [Page] {
        render(StarPRNTParser.parse(data), options: options)
    }

    // MARK: - Commands

    public mutating func apply(_ command: Command) {
        switch command {
        case .text(let bytes): line.append(contentsOf: bytes.map { ($0, style) })
        case .horizontalTab: line.append((0x09, style))
        case .lineFeed: lineFeed()
        case .initialize: resetState()
        case .bold(let on): style.bold = on
        case .invert(let on): style.invert = on
        case .underline(let n): style.underline = n
        case .font(let font): style.font = font
        case .magnify(let w, let h): (style.magWidth, style.magHeight) = (w, h)
        case .alignment(let a): alignment = a
        case .linePitch(let dots): linePitch = dots
        case .charSpacing(let dots): charSpacing = dots
        case .codePage(let n): codePage = n
        case .tabStops(let stops): tabStops = stops
        case .feedLines(let n): feed(n * linePitch)
        case .feedDots(let n): feed(n)
        case .cut(let type): cut(type)
        case .drawerKick(let channel): events.append(.drawerKick(channel: channel, row: cursor))
        case .unknown(let bytes): warn("unknown command \(bytes.hexString)")
        case .malformed(let reason, _): warn("malformed command: \(reason)")
        default: applyGraphics(command)
        }
    }

    public mutating func finish() -> [Page] {
        flushLine()
        if cursor > 0 || !events.isEmpty { finishPage(cut: nil) }
        return pages
    }

    mutating func warn(_ message: String) {
        events.append(.warning(message, row: cursor))
    }

    private mutating func resetState() {
        style = TextStyle()
        alignment = .left
        linePitch = 32
        charSpacing = 0
        tabStops = []
        qr = QRState()
    }

    private mutating func lineFeed() {
        guard line.isEmpty else { return flushLine() }
        advance(linePitch)
    }

    mutating func feed(_ dots: Int) {
        flushLine()
        advance(dots)
    }

    mutating func advance(_ dots: Int) {
        cursor += max(dots, 0)
        paper.extend(toHeight: cursor)
    }

    private mutating func cut(_ type: CutType) {
        flushLine()
        if type.feedsFirst { advance(options.cutFeedDots) }
        finishPage(cut: type)
    }

    private mutating func finishPage(cut: CutType?) {
        paper.extend(toHeight: cursor)
        pages.append(Page(bitmap: paper, cut: cut, events: events))
        paper = PaperBitmap(width: options.dotsPerLine)
        cursor = 0
        events = []
    }

    /// x offset for content `width` dots wide under the current alignment.
    func alignedX(width: Int) -> Int {
        switch alignment {
        case .left: 0
        case .center: max((options.dotsPerLine - width) / 2, 0)
        case .right: max(options.dotsPerLine - width, 0)
        }
    }

    // MARK: - Text layout

    /// Prints the buffered line (wrapping at the paper edge, as the printer does).
    mutating func flushLine() {
        guard !line.isEmpty else { return }
        let glyphs = decodeLine()
        line.removeAll()

        var row: [Glyph] = []
        var x = 0
        for (character, glyphStyle) in glyphs {
            let width = glyphWidth(character, style: glyphStyle, at: x)
            if x + width > options.dotsPerLine, !row.isEmpty {
                draw(row)
                row = []
                x = 0
            }
            row.append(Glyph(character: character, style: glyphStyle, width: glyphWidth(character, style: glyphStyle, at: x)))
            x += row.last!.width
        }
        draw(row)
    }

    private func glyphWidth(_ character: Character, style: TextStyle, at x: Int) -> Int {
        let cell = style.cellWidth * style.magWidth + charSpacing
        guard character == "\t" else { return cell }
        let next = tabStops.map { Int($0) * TextStyle().cellWidth }.first { $0 > x }
        return next.map { $0 - x } ?? cell
    }

    private mutating func draw(_ glyphs: [Glyph]) {
        guard !glyphs.isEmpty else { return }
        let lineWidth = glyphs.reduce(0) { $0 + $1.width }
        let lineHeight = glyphs.map { TextStyle.cellHeight * $0.style.magHeight }.max() ?? TextStyle.cellHeight
        var x = alignedX(width: lineWidth)
        for glyph in glyphs {
            drawGlyph(glyph, x: x, lineTop: cursor, lineHeight: lineHeight)
            x += glyph.width
        }
        advance(lineHeight + max(linePitch - TextStyle.cellHeight, 0))
    }

    private mutating func drawGlyph(_ glyph: Glyph, x: Int, lineTop: Int, lineHeight: Int) {
        let s = glyph.style
        let height = TextStyle.cellHeight * s.magHeight
        let y = lineTop + lineHeight - height   // characters sit on the line's baseline
        if glyph.character == "\t" || glyph.character == " " {
            if s.invert { paper.fill(x: x, y: y, width: glyph.width, height: height) }
        } else {
            let mask = GlyphCache.shared
                .mask(for: glyph.character, cellWidth: s.cellWidth, cellHeight: TextStyle.cellHeight, bold: s.bold)
                .scaled(x: s.magWidth, y: s.magHeight)
            if s.invert { paper.fill(x: x, y: y, width: glyph.width, height: height) }
            paper.blit(mask, x: x, y: y, invert: s.invert)
        }
        if s.underline > 0 {
            paper.fill(x: x, y: y + height - s.underline, width: glyph.width, height: s.underline, ink: s.invert ? 0 : 1)
        }
    }

    /// Bytes → characters, decoding each same-style run with the active code page (0x80 = UTF-8).
    private func decodeLine() -> [(Character, TextStyle)] {
        var result: [(Character, TextStyle)] = []
        var start = 0
        while start < line.count {
            let runStyle = line[start].style
            var end = start
            while end < line.count, line[end].style == runStyle { end += 1 }
            let bytes = Data(line[start..<end].map(\.byte))
            result.append(contentsOf: decode(bytes).map { ($0, runStyle) })
            start = end
        }
        return result
    }

    private func decode(_ bytes: Data) -> String {
        guard codePage != 0x80 else { return String(decoding: bytes, as: UTF8.self) }
        return String(data: bytes, encoding: .windowsCP1252) ?? String(decoding: bytes, as: UTF8.self)
    }
}
