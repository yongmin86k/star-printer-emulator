import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// QR settings accumulate across commands until `ESC GS y P`.
struct QRState: Equatable {
    var model = 2
    var level = 1
    var cellSize = 3
    var data = Data()
}

extension Renderer {
    /// Graphics: raster bands, Star raster mode, QR, barcodes.
    mutating func applyGraphics(_ command: Command) {
        switch command {
        case .raster(let band): drawRaster(band)
        case .rasterMode: flushLine()
        case .rasterLine(let row): drawRasterLine(row)
        case .rasterModeSetting(let letter, let value): rasterModeSetting(letter, value)
        case .formFeed: rasterPageEnd()
        case .qrModel(let n): qr.model = n
        case .qrLevel(let n): qr.level = n
        case .qrCellSize(let n): qr.cellSize = n
        case .qrData(let data): qr.data = data
        case .qrPrint: drawQR()
        case .barcode(let spec): drawBarcode(spec)
        default: break   // session control, ignored and peripheral setup commands
        }
    }

    // MARK: Raster

    /// `ESC GS S`: one band, placed by the current alignment. Pending text prints first.
    private mutating func drawRaster(_ band: RasterBand) {
        flushLine()
        let x = alignedX(width: band.widthBytes * 8)
        for row in 0..<band.height {
            let start = band.bits.startIndex + row * band.widthBytes
            paper.blitPackedRow(band.bits[start..<start + band.widthBytes], x: x, y: cursor + row)
        }
        advance(band.height)
    }

    /// Star raster mode `b nL nH d…`: one dot row from the left edge (short rows are blank on the right).
    private mutating func drawRasterLine(_ row: Data) {
        paper.blitPackedRow(row, x: 0, y: cursor)
        advance(1)
    }

    /// Star raster mode settings. `Y n` moves down n dots; `e n` picks the cut done at the next `ESC FF`.
    private mutating func rasterModeSetting(_ letter: UInt8, _ value: String) {
        switch letter {
        case UInt8(ascii: "Y"): advance(Int(value) ?? 0)
        case UInt8(ascii: "e"): rasterPageCut = Self.rasterCuts[value] ?? .partialAfterFeed
        default: break
        }
    }

    /// `ESC * r e n` → cut, from the TSP100IIIW capture and paper check (protocol-notes §8). Other values: UNVERIFIED,
    /// treated as partial (Shopify sends 13).
    private static let rasterCuts: [String: CutType] = ["13": .partialAfterFeed, "9": .fullAfterFeed]

    /// `ESC FF n` ends a raster-mode page with the cut chosen by `ESC * r e`.
    private mutating func rasterPageEnd() {
        flushLine()
        guard cursor > 0 else { return }
        apply(.cut(rasterPageCut))
    }

    // MARK: QR

    private mutating func drawQR() {
        flushLine()
        guard !qr.data.isEmpty else { return warn("QR print without data") }
        if qr.model != 2 { warn("QR model \(qr.model) rendered as model 2") }
        guard let modules = Symbols.qr(qr.data, level: qr.level) else { return warn("QR encoding failed") }
        let cell = max(qr.cellSize, 1)
        let mask = modules.scaled(x: cell, y: cell)
        paper.blit(mask, x: alignedX(width: mask.width), y: cursor)
        advance(mask.height)
    }

    // MARK: Barcode

    /// `ESC b`: Code128 is drawn; other symbologies get a labelled placeholder and a warning.
    private mutating func drawBarcode(_ spec: BarcodeSpec) {
        flushLine()
        let text = String(decoding: spec.data, as: UTF8.self)
        let moduleWidth = (1...3).contains(spec.mode) ? Int(spec.mode) + 1 : 2   // UNVERIFIED: n3 = dots − 1
        let height = max(spec.heightDots, 8)
        var mask: DotMask
        if spec.symbology == 6, let modules = Symbols.code128(text) {
            mask = modules.scaled(x: moduleWidth, y: height)
        } else {
            warn("barcode symbology \(spec.symbology) not supported; drawn as placeholder")
            mask = Symbols.placeholder(width: min(options.dotsPerLine, 24 * moduleWidth * max(text.count, 4)), height: height)
        }
        paper.blit(mask, x: alignedX(width: mask.width), y: cursor)
        advance(mask.height)
        guard spec.hri == 2 || spec.hri == 4 else { return }   // UNVERIFIED: 2/4 = HRI below
        line.append(contentsOf: text.utf8.map { ($0, TextStyle()) })
        flushLine()
    }
}

/// 1-dot-per-module symbol encoders (CoreImage), cropped to the dark modules (no quiet zone).
enum Symbols {
    private static let context = CIContext(options: [.useSoftwareRenderer: true])

    static func qr(_ data: Data, level: Int) -> DotMask? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        filter.correctionLevel = ["L", "M", "Q", "H"][min(max(level, 0), 3)]
        return filter.outputImage.flatMap(mask(from:))
    }

    static func code128(_ text: String) -> DotMask? {
        guard let message = text.data(using: .ascii) else { return nil }
        let filter = CIFilter.code128BarcodeGenerator()
        filter.message = message
        filter.quietSpace = 0
        filter.barcodeHeight = 1
        return filter.outputImage.flatMap(mask(from:)).map(firstRowOnly)
    }

    /// Box outline with a diagonal — "a barcode was here".
    static func placeholder(width: Int, height: Int) -> DotMask {
        var mask = DotMask(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width where y == 0 || y == height - 1 || x == 0 || x == width - 1 || x == y * width / height {
                mask.ink[y * width + x] = 1
            }
        }
        return mask
    }

    private static func firstRowOnly(_ mask: DotMask) -> DotMask {
        DotMask(width: mask.width, height: 1, ink: Array(mask.ink.prefix(mask.width)))
    }

    /// Rasterises a 1-px-per-module CIImage and crops away the white border.
    private static func mask(from image: CIImage) -> DotMask? {
        let extent = image.extent.integral
        let width = Int(extent.width), height = Int(extent.height)
        guard width > 0, height > 0,
              let cg = context.createCGImage(image, from: extent),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = ctx.data!.bindMemory(to: UInt8.self, capacity: width * height)
        let dark = (0..<width * height).map { pixels[$0] < 128 }

        let rows = (0..<height).filter { y in (0..<width).contains { dark[y * width + $0] } }
        let cols = (0..<width).filter { x in (0..<height).contains { dark[$0 * width + x] } }
        guard let top = rows.first, let bottom = rows.last, let left = cols.first, let right = cols.last else { return nil }
        let w = right - left + 1, h = bottom - top + 1
        var mask = DotMask(width: w, height: h)
        for y in 0..<h {
            for x in 0..<w where dark[(top + y) * width + left + x] {
                mask.ink[y * w + x] = 1
            }
        }
        return mask
    }
}
