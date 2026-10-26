import CoreGraphics
import Foundation
import ImageIO

public enum PNGExporter {
    public enum ExportError: Error, CustomStringConvertible {
        case emptyImage
        case encodeFailed

        public var description: String {
            switch self {
            case .emptyImage: "Nothing to export: the page has no height."
            case .encodeFailed: "PNG encoding failed."
            }
        }
    }

    /// 1 dot = 1 pixel, with DPI metadata so the PNG prints at true receipt size.
    public static func png(_ bitmap: PaperBitmap, dpi: Int = DeviceProfile.mcPrint3.dpi) throws -> Data {
        guard let image = bitmap.cgImage() else { throw ExportError.emptyImage }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else {
            throw ExportError.encodeFailed
        }
        let properties = [
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi,
        ] as CFDictionary
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else { throw ExportError.encodeFailed }
        return output as Data
    }

    /// All pages on one strip; each cut is marked by a dashed line in a 16-dot gap.
    public static func stacked(_ pages: [Page], gap: Int = 16) -> PaperBitmap {
        guard let first = pages.first else { return PaperBitmap(width: DeviceProfile.mcPrint3.dotsPerLine) }
        var strip = first.bitmap
        for page in pages.dropFirst() {
            let cutRow = strip.height + gap / 2
            strip.extend(toHeight: strip.height + gap)
            for x in stride(from: 0, to: strip.width, by: 8) {
                strip.fill(x: x, y: cutRow, width: 4, height: 1)
            }
            strip.append(page.bitmap)
        }
        return strip
    }
}
