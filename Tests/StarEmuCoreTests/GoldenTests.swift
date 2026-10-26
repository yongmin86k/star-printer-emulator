import Foundation
import Testing
@testable import StarEmuCore

/// Regression snapshots of whole SDK documents. Regenerate with `UPDATE_GOLDENS=1 swift test`
/// after an intended rendering change, and review the PNG diff before committing.
@Suite struct GoldenTests {
    static let documents = [
        "t-plain", "t-bold", "t-center", "t-mag2x3", "t-invert", "t-underline", "t-fontb", "t-utf8",
        "receipt", "image", "image-narrow", "qr", "barcode",
    ]

    @Test(arguments: documents)
    func sdkDocument(name: String) throws {
        let pages = Renderer.render(Fixture.sdk(name))
        try Golden.assertMatches(PNGExporter.stacked(pages), named: name)
    }

    /// TSP100IIIW (StarGraphic) documents: raster only.
    @Test(arguments: ["image", "image-narrow", "qr", "receipt"])
    func tsp100IIIWDocument(name: String) throws {
        let pages = Renderer.render(Fixture.data("sdk-tsp100iiiw/\(name).bin"))
        try Golden.assertMatches(PNGExporter.stacked(pages), named: "tsp100iiiw-\(name)")
    }
}
