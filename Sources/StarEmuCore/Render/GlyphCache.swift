import CoreGraphics
import CoreText
import Foundation

/// Renders characters into fixed-size 1-bit cells (Font A 12×24, Font B 9×24) with a monospaced
/// system font, then caches them. Glyph shapes differ from the printer's ROM font; cell sizes do not,
/// so line breaks and columns match the device.
public final class GlyphCache: @unchecked Sendable {   // `cache` guarded by `lock`
    public static let shared = GlyphCache()

    private struct Key: Hashable {
        let character: Character
        let width: Int
        let height: Int
        let bold: Bool
    }

    private var cache: [Key: DotMask] = [:]
    private let lock = NSLock()

    public func mask(for character: Character, cellWidth: Int, cellHeight: Int, bold: Bool) -> DotMask {
        let key = Key(character: character, width: cellWidth, height: cellHeight, bold: bold)
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[key] { return cached }
        let mask = Self.render(character, cellWidth: cellWidth, cellHeight: cellHeight, bold: bold)
        cache[key] = mask
        return mask
    }

    private static func render(_ character: Character, cellWidth: Int, cellHeight: Int, bold: Bool) -> DotMask {
        guard character != " ", let context = CGContext(
            data: nil, width: cellWidth, height: cellHeight, bitsPerComponent: 8, bytesPerRow: cellWidth,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return DotMask(width: cellWidth, height: cellHeight)
        }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: cellWidth, height: cellHeight))
        context.setShouldSmoothFonts(false)

        // Size the font so ascent + descent fills the cell height, then squeeze horizontally to the cell width.
        let unit = CTFontCreateWithName((bold ? "Menlo-Bold" : "Menlo-Regular") as CFString, 1, nil)
        let size = CGFloat(cellHeight - 1) / (CTFontGetAscent(unit) + CTFontGetDescent(unit))
        let font = CTFontCreateCopyWithAttributes(unit, size, nil, nil)
        let advance = CGFloat(0.6021) * size   // Menlo advance width ≈ 0.602 em
        let attributes = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
        ] as [NSAttributedString.Key: Any]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: String(character), attributes: attributes))

        context.scaleBy(x: CGFloat(cellWidth) / advance, y: 1)
        context.textPosition = CGPoint(x: 0, y: CTFontGetDescent(font) + 0.5)
        CTLineDraw(line, context)

        guard let data = context.data else { return DotMask(width: cellWidth, height: cellHeight) }
        let pixels = data.bindMemory(to: UInt8.self, capacity: cellWidth * cellHeight)
        let ink = (0..<cellWidth * cellHeight).map { pixels[$0] < 128 ? UInt8(1) : UInt8(0) }
        return DotMask(width: cellWidth, height: cellHeight, ink: ink)
    }
}
