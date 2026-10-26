import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import StarEmuCore

/// Golden-image comparison. Goldens live in the *source* tree (Tests/StarEmuCoreTests/Fixtures/golden)
/// so `UPDATE_GOLDENS=1 swift test` can rewrite them. Fails when > `tolerance` of dots differ and writes
/// actual/expected/diff PNGs to $STAREMU_GOLDEN_DIFFS (or the temp dir).
enum Golden {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/golden", isDirectory: true)

    static var diffDirectory: URL {
        let base = ProcessInfo.processInfo.environment["STAREMU_GOLDEN_DIFFS"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("staremu-golden-diffs")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static func assertMatches(_ bitmap: PaperBitmap, named name: String, tolerance: Double = 0.005,
                              sourceLocation: SourceLocation = #_sourceLocation) throws {
        let url = directory.appendingPathComponent("\(name).png")
        if ProcessInfo.processInfo.environment["UPDATE_GOLDENS"] == "1" {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try PNGExporter.png(bitmap).write(to: url)
            return
        }
        guard let expected = load(url) else {
            Issue.record("Missing golden \(name).png — run UPDATE_GOLDENS=1 swift test", sourceLocation: sourceLocation)
            return
        }
        guard expected.width == bitmap.width, expected.height == bitmap.height else {
            try writeDiff(name, actual: bitmap, expected: expected)
            Issue.record("\(name): size \(bitmap.width)x\(bitmap.height) != golden \(expected.width)x\(expected.height)", sourceLocation: sourceLocation)
            return
        }
        let differing = zip(bitmap.ink, expected.ink).filter { $0 != $1 }.count
        let ratio = Double(differing) / Double(max(bitmap.ink.count, 1))
        if ratio > tolerance {
            try writeDiff(name, actual: bitmap, expected: expected)
            Issue.record("\(name): \(differing) dots differ (\(String(format: "%.2f", ratio * 100))%); see \(diffDirectory.path)", sourceLocation: sourceLocation)
        }
    }

    /// Reads a golden PNG back into a bitmap (dark pixels = ink).
    static func load(_ url: URL) -> PaperBitmap? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: image.width, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let pixels = context.data!.bindMemory(to: UInt8.self, capacity: image.width * image.height)
        var bitmap = PaperBitmap(width: image.width)
        bitmap.extend(toHeight: image.height)
        for y in 0..<image.height {
            for x in 0..<image.width where pixels[y * image.width + x] < 128 {
                bitmap.fill(x: x, y: y, width: 1, height: 1)
            }
        }
        return bitmap
    }

    private static func writeDiff(_ name: String, actual: PaperBitmap, expected: PaperBitmap) throws {
        try PNGExporter.png(actual).write(to: diffDirectory.appendingPathComponent("\(name)-actual.png"))
        try PNGExporter.png(expected).write(to: diffDirectory.appendingPathComponent("\(name)-expected.png"))
        guard actual.width == expected.width else { return }
        var diff = PaperBitmap(width: actual.width)
        diff.extend(toHeight: max(actual.height, expected.height))
        for y in 0..<min(actual.height, expected.height) {
            for x in 0..<actual.width where actual[x, y] != expected[x, y] {
                diff.fill(x: x, y: y, width: 1, height: 1)
            }
        }
        if diff.height > 0 { try PNGExporter.png(diff).write(to: diffDirectory.appendingPathComponent("\(name)-diff.png")) }
    }
}
