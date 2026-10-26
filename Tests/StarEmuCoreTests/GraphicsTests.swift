import CoreGraphics
import Foundation
import Testing
import Vision
@testable import StarEmuCore

@Suite struct GraphicsTests {
    // MARK: Raster

    @Test func singleBandCheckerboard() throws {
        let bits = Data((0..<8).flatMap { row in [UInt8](repeating: row.isMultiple(of: 2) ? 0xAA : 0x55, count: 72) })
        let page = try #require(Renderer.render([.raster(RasterBand(widthBytes: 72, height: 8, bits: bits))]).first)
        #expect(page.bitmap.height == 8)
        for y in 0..<8 {
            for x in 0..<576 {
                #expect(page.bitmap[x, y] == ((x + y).isMultiple(of: 2)))
            }
        }
    }

    @Test func fullWidthImageRoundTripsExactly() throws {
        let data = Fixture.sdk("image")
        let bands = StarPRNTParser.parse(data).compactMap { cmd -> RasterBand? in if case .raster(let b) = cmd { b } else { nil } }
        let page = try #require(Renderer.render(data).first)
        #expect(page.bitmap.height == 96)   // 12 bands × 8 rows, no gaps
        #expect(repack(page.bitmap, x: 0, widthBytes: 72) == bands.reduce(Data()) { $0 + $1.bits })
    }

    @Test func narrowImageIsCentered() throws {
        let page = try #require(Renderer.render(Fixture.sdk("image-narrow")).first)
        #expect(page.bitmap.height == 40)
        let x0 = (576 - 200) / 2
        let band = try #require(StarPRNTParser.parse(Fixture.sdk("image-narrow")).compactMap { cmd -> RasterBand? in
            if case .raster(let b) = cmd { b } else { nil }
        }.first)
        #expect(repack(page.bitmap, x: x0, widthBytes: 25) == band.bits)
        #expect((0..<40).allSatisfy { y in (0..<x0).allSatisfy { !page.bitmap[$0, y] } })
    }

    @Test func pendingTextPrintsBeforeRaster() throws {
        let band = RasterBand(widthBytes: 72, height: 4, bits: Data(repeating: 0xFF, count: 288))
        let page = try #require(Renderer.render([.text(Data("A".utf8)), .raster(band)]).first)
        #expect(page.bitmap.height == 32 + 4)
        #expect((0..<576).allSatisfy { page.bitmap[$0, 32] })
        #expect(!(0..<576).allSatisfy { page.bitmap[$0, 0] })
    }

    @Test func starRasterModeLinesAndMoves() throws {
        let commands: [Command] = [
            .rasterMode(true), .rasterLine(Data([0xFF])), .rasterModeSetting(UInt8(ascii: "Y"), "010"),
            .rasterLine(Data([0x80])), .formFeed(0x19), .formFeed(0x00), .rasterMode(false),
        ]
        let pages = Renderer.render(commands)
        #expect(pages.count == 1)                     // the second form feed has nothing to eject
        let page = try #require(pages.first)
        #expect(page.cut == .partialAfterFeed)
        #expect((0..<8).allSatisfy { page.bitmap[$0, 0] } && !page.bitmap[8, 0])
        #expect(page.bitmap[0, 11] && !page.bitmap[1, 11])
    }

    // MARK: QR

    @Test func qrDecodesToPayload() throws {
        let page = try #require(Renderer.render(Fixture.sdk("qr")).first)
        #expect(try decode(page.bitmap, symbology: .qr) == "https://example.com/r/123")
        #expect(page.warnings.isEmpty)
    }

    @Test func qrCellSizeScalesExactly() throws {
        func width(_ cell: Int) throws -> Int {
            let page = try #require(Renderer.render([.qrCellSize(cell), .qrData(Data("hello".utf8)), .qrPrint]).first)
            return page.bitmap.height
        }
        #expect(try width(8) == 2 * width(4))
    }

    @Test func qrIsAligned() throws {
        let page = try #require(Renderer.render([.alignment(.center), .qrCellSize(4), .qrData(Data("x".utf8)), .qrPrint]).first)
        let size = page.bitmap.height
        let left = (576 - size) / 2
        #expect(page.bitmap[left, 0] && !page.bitmap[left - 1, 0])
    }

    @Test func qrModel1Warns() throws {
        let page = try #require(Renderer.render([.qrModel(1), .qrData(Data("x".utf8)), .qrPrint]).first)
        #expect(page.warnings.count == 1)
    }

    @Test func qrWithoutDataWarns() throws {
        let page = try #require(Renderer.render([.qrPrint]).first)
        #expect(page.warnings == ["QR print without data"])
    }

    // MARK: Barcode

    @Test func code128DecodesAndHasHRI() throws {
        let page = try #require(Renderer.render(Fixture.sdk("barcode")).first)
        #expect(try decode(page.bitmap, symbology: .code128) == "123456")
        #expect(page.bitmap.height == 80 + 32)        // bars (n4 = 80 dots) + one HRI text line
        #expect(page.warnings.isEmpty)
    }

    @Test func unsupportedSymbologyIsPlaceholderWithWarning() throws {
        let spec = BarcodeSpec(symbology: 3, hri: 1, mode: 2, heightDots: 40, data: Data("4901234567894".utf8))
        let page = try #require(Renderer.render([.barcode(spec)]).first)
        #expect(page.bitmap.height == 40)
        #expect(page.warnings.count == 1)
    }

    // MARK: Helpers

    /// Packs a region of the bitmap back into raster bytes (MSB first).
    private func repack(_ bitmap: PaperBitmap, x: Int, widthBytes: Int) -> Data {
        var out = Data()
        for y in 0..<bitmap.height {
            for byteIndex in 0..<widthBytes {
                var byte: UInt8 = 0
                for bit in 0..<8 where bitmap[x + byteIndex * 8 + bit, y] { byte |= 0x80 >> bit }
                out.append(byte)
            }
        }
        return out
    }

    /// Decodes a symbol with Vision after adding a white quiet zone and upscaling.
    private func decode(_ bitmap: PaperBitmap, symbology: VNBarcodeSymbology) throws -> String? {
        let margin = 40
        var padded = PaperBitmap(width: bitmap.width + 2 * margin)
        padded.extend(toHeight: bitmap.height + 2 * margin)
        for y in 0..<bitmap.height {
            for x in 0..<bitmap.width where bitmap[x, y] {
                padded.fill(x: x + margin, y: y + margin, width: 1, height: 1)
            }
        }
        let image = try #require(padded.cgImage())
        let request = VNDetectBarcodesRequest()
        request.symbologies = [symbology]
        try VNImageRequestHandler(cgImage: image).perform([request])
        return request.results?.first?.payloadStringValue
    }
}
