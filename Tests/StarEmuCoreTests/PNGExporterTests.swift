import Foundation
import ImageIO
import Testing
@testable import StarEmuCore

@Suite struct PNGExporterTests {
    @Test func pngHasDotSizeAndDPI() throws {
        let page = try #require(Renderer.render([.text(Data("Hello".utf8)), .lineFeed]).first)
        let png = try PNGExporter.png(page.bitmap)

        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 576)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 32)
        #expect((properties[kCGImagePropertyDPIWidth] as? Double).map { Int($0.rounded()) } == 203)
    }

    @Test func emptyBitmapThrows() {
        #expect(throws: PNGExporter.ExportError.self) {
            _ = try PNGExporter.png(PaperBitmap(width: 576))
        }
    }

    @Test func stackedPagesIncludeGaps() {
        let pages = Renderer.render([.text(Data("1".utf8)), .lineFeed, .cut(.full), .text(Data("2".utf8)), .lineFeed, .cut(.full)])
        let strip = PNGExporter.stacked(pages)
        #expect(strip.height == pages[0].bitmap.height + 16 + pages[1].bitmap.height)
    }
}
