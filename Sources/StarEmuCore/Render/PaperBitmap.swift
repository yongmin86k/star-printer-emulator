import CoreGraphics
import Foundation

/// 1-bit mask (glyph, barcode module, …): `ink[y * width + x] == 1` means a black dot.
public struct DotMask: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public var ink: [UInt8]

    public init(width: Int, height: Int, ink: [UInt8]? = nil) {
        self.width = width
        self.height = height
        self.ink = ink ?? [UInt8](repeating: 0, count: width * height)
    }

    public subscript(x: Int, y: Int) -> Bool {
        ink[y * width + x] != 0
    }

    /// Nearest-neighbour integer scaling — what the print head does for magnified characters.
    public func scaled(x sx: Int, y sy: Int) -> DotMask {
        guard sx != 1 || sy != 1 else { return self }
        var out = DotMask(width: width * sx, height: height * sy)
        for y in 0..<out.height {
            let srcRow = (y / sy) * width
            for x in 0..<out.width {
                out.ink[y * out.width + x] = ink[srcRow + x / sx]
            }
        }
        return out
    }
}

/// The paper roll: fixed width (dots per line), grows downward as the printer feeds.
public struct PaperBitmap: Sendable, Equatable {
    public let width: Int
    public private(set) var height: Int
    public private(set) var ink: [UInt8]

    public init(width: Int, height: Int = 0) {
        self.width = width
        self.height = height
        ink = [UInt8](repeating: 0, count: width * height)
    }

    public subscript(x: Int, y: Int) -> Bool {
        ink[y * width + x] != 0
    }

    public var inkCount: Int {
        ink.reduce(0) { $0 + Int($1) }
    }

    public mutating func extend(toHeight newHeight: Int) {
        guard newHeight > height else { return }
        ink.append(contentsOf: repeatElement(0, count: (newHeight - height) * width))
        height = newHeight
    }

    /// Fills (or clears) a rectangle, clipped to the paper width; grows the paper if needed.
    public mutating func fill(x: Int, y: Int, width w: Int, height h: Int, ink value: UInt8 = 1) {
        extend(toHeight: y + h)
        let x0 = max(x, 0), x1 = min(x + w, width)
        guard x0 < x1 else { return }
        for row in y..<(y + h) {
            ink.replaceSubrange(row * width + x0..<row * width + x1, with: repeatElement(value, count: x1 - x0))
        }
    }

    /// Stamps a mask's black dots. With `invert`, the mask's box is filled and its dots are cleared.
    public mutating func blit(_ mask: DotMask, x: Int, y: Int, invert: Bool = false) {
        extend(toHeight: y + mask.height)
        if invert { fill(x: x, y: y, width: mask.width, height: mask.height) }
        let value: UInt8 = invert ? 0 : 1
        for my in 0..<mask.height {
            let row = (y + my) * width
            for mx in 0..<mask.width where mask.ink[my * mask.width + mx] != 0 {
                let px = x + mx
                guard px >= 0, px < width else { continue }
                ink[row + px] = value
            }
        }
    }

    /// Writes one row of packed bits (MSB = leftmost dot, 1 = black) starting at `x`.
    public mutating func blitPackedRow(_ bytes: some Collection<UInt8>, x: Int, y: Int) {
        extend(toHeight: y + 1)
        let row = y * width
        var px = x
        for byte in bytes {
            for bit in 0..<8 where byte & (0x80 >> bit) != 0 {
                let dx = px + bit
                if dx >= 0, dx < width { ink[row + dx] = 1 }
            }
            px += 8
        }
    }

    /// Appends another bitmap below this one (same width), with `gap` blank rows in between.
    public mutating func append(_ other: PaperBitmap, gap: Int = 0) {
        extend(toHeight: height + gap)
        ink.append(contentsOf: other.ink.prefix(other.height * width))
        height += other.height
    }

    /// 8-bit grayscale image: black dots on white paper.
    public func cgImage() -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        let gray = ink.map { $0 != 0 ? UInt8(0) : UInt8(255) }
        guard let provider = CGDataProvider(data: Data(gray) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }
}
