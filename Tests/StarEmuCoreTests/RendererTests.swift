import Foundation
import Testing
@testable import StarEmuCore

@Suite struct RendererTests {
    private func render(_ commands: [Command]) -> [Page] {
        Renderer.render(commands)
    }

    private func text(_ s: String) -> Command { .text(Data(s.utf8)) }

    /// Bounding box of black dots: (minX, minY, maxX, maxY), nil if blank.
    private func inkBox(_ bitmap: PaperBitmap) -> (Int, Int, Int, Int)? {
        var box: (Int, Int, Int, Int)?
        for y in 0..<bitmap.height {
            for x in 0..<bitmap.width where bitmap[x, y] {
                box = box.map { (min($0.0, x), min($0.1, y), max($0.2, x), max($0.3, y)) } ?? (x, y, x, y)
            }
        }
        return box
    }

    @Test func fortyEightFontACharactersFitOneLine() throws {
        let pages = render([text(String(repeating: "X", count: 48)), .lineFeed])
        let page = try #require(pages.first)
        #expect(pages.count == 1)
        #expect(page.bitmap.width == 576)
        #expect(page.bitmap.height == 32)   // one 24-dot line + 8 dots spacing (4 mm pitch)
        let box = try #require(inkBox(page.bitmap))
        #expect(box.2 > 564)                 // last cell reaches the right edge
    }

    @Test func fortyNinthCharacterWraps() throws {
        let page = try #require(render([text(String(repeating: "X", count: 49)), .lineFeed]).first)
        #expect(page.bitmap.height == 64)
        let box = try #require(inkBox(page.bitmap))
        #expect(box.3 >= 32)                  // ink on the second line
    }

    @Test func fontBHasSixtyFourColumns() throws {
        let page = try #require(render([.font(.b), text(String(repeating: "X", count: 64)), .lineFeed]).first)
        #expect(page.bitmap.height == 32)
    }

    @Test(arguments: [(Alignment.left, 0, 24), (.center, 276, 300), (.right, 552, 576)])
    func alignmentOffsets(alignment: Alignment, minX: Int, maxX: Int) throws {
        let page = try #require(render([.alignment(alignment), text("AB"), .lineFeed]).first)
        let box = try #require(inkBox(page.bitmap))
        #expect(box.0 >= minX)
        #expect(box.2 < maxX)
    }

    @Test func magnificationScalesTheBaseGlyph() throws {
        let base = try #require(render([text("A"), .lineFeed]).first).bitmap
        let big = try #require(render([.magnify(width: 2, height: 2), text("A"), .lineFeed]).first).bitmap
        #expect(big.height == 48 + 8)
        for y in 0..<48 {
            for x in 0..<24 {
                #expect(big[x, y] == base[x / 2, y / 2])
            }
        }
    }

    @Test func invertFillsTheCell() throws {
        let page = try #require(render([.invert(true), text("A"), .lineFeed]).first)
        var ink = 0
        for y in 0..<24 { for x in 0..<12 where page.bitmap[x, y] { ink += 1 } }
        #expect(ink > 12 * 24 / 2)
    }

    @Test func underlineDrawsBottomRow() throws {
        let page = try #require(render([.underline(1), text("  "), .lineFeed]).first)
        #expect((0..<24).allSatisfy { page.bitmap[$0, 23] })
    }

    @Test func boldDiffersFromRegular() throws {
        let regular = try #require(render([text("A"), .lineFeed]).first).bitmap
        let bold = try #require(render([.bold(true), text("A"), .lineFeed]).first).bitmap
        #expect(regular != bold)
        #expect(bold.inkCount > regular.inkCount)
    }

    @Test func feedLinesAndDots() throws {
        let lines = try #require(render([text("A"), .lineFeed, .feedLines(3)]).first)
        #expect(lines.bitmap.height == 32 + 3 * 32)
        let dots = try #require(render([text("A"), .lineFeed, .feedDots(80)]).first)
        #expect(dots.bitmap.height == 32 + 80)
    }

    @Test func emptyLineFeedAdvancesOnePitch() throws {
        let page = try #require(render([.lineFeed, .lineFeed]).first)
        #expect(page.bitmap.height == 64)
    }

    @Test func cutEndsPageAfterFeed() throws {
        let pages = render([text("A"), .lineFeed, .cut(.partialAfterFeed)])
        #expect(pages.count == 1)
        #expect(pages[0].cut == .partialAfterFeed)
        #expect(pages[0].bitmap.height == 32 + 24)
    }

    @Test func twoCutsTwoPages() {
        let pages = render([text("1"), .lineFeed, .cut(.full), text("2"), .lineFeed, .cut(.partial)])
        #expect(pages.map(\.cut) == [.full, .partial])
    }

    @Test func uncutJobIsOnePage() {
        let pages = render([text("A"), .lineFeed])
        #expect(pages.count == 1)
        #expect(pages[0].cut == nil)
    }

    @Test func textWithoutLineFeedIsPrintedAtEnd() throws {
        let page = try #require(Renderer.render(Fixture.sdk("t-noeol")).first)
        #expect(page.bitmap.inkCount > 0)
    }

    @Test func utf8SplitAcrossCommandsDecodes() throws {
        let whole = try #require(render([text("é"), .lineFeed]).first).bitmap
        let split = try #require(render([.text(hex("c3")), .text(hex("a9")), .lineFeed]).first).bitmap
        #expect(whole == split)
        #expect(whole.inkCount > 0)
    }

    @Test func styleResetsDoNotLeakAcrossLines() throws {
        let page = try #require(render([.magnify(width: 2, height: 2), text("A"), .lineFeed, .magnify(width: 1, height: 1), text("A"), .lineFeed]).first)
        #expect(page.bitmap.height == (48 + 8) + 32)
    }

    @Test func drawerKickIsAnEventNotInk() throws {
        let page = try #require(Renderer.render(Fixture.sdk("drawer")).first)
        #expect(page.drawerKicks == [1])
        #expect(page.bitmap.inkCount == 0)
    }

    /// StarGraphic cut: `ESC * r e n` picks the cut done at the next `ESC FF` (TSP100IIIW capture + paper check).
    @Test func rasterEOTModeChoosesCut() throws {
        let line = hex("62 01 00 ff")
        let partial = hex("1b 2a 72 41") + line + hex("1b 2a 72 65 31 33 00 1b 0c 19 1b 2a 72 42")
        let full = hex("1b 2a 72 41") + line + hex("1b 2a 72 65 39 00 1b 0c 19 1b 2a 72 42")
        #expect(try #require(Renderer.render(partial).first).cut == .partialAfterFeed)
        #expect(try #require(Renderer.render(full).first).cut == .fullAfterFeed)
        #expect(try #require(Renderer.render(Fixture.data("sdk-tsp100iiiw/receipt.bin")).first).cut == .partialAfterFeed)
    }

    @Test func blankJobsAreRecognised() {
        #expect(Renderer.render(Fixture.data("sdk-tsp100iiiw/t-plain.bin")).isBlank)
        #expect(!Renderer.render(Fixture.data("sdk-tsp100iiiw/image.bin")).isBlank)
        #expect(!Renderer.render(Fixture.sdk("drawer")).isBlank)   // a drawer kick is something
    }

    /// POS apps often open the drawer with a separate print call after the receipt; the app labels that job.
    @Test func drawerOnlyJobsAreRecognised() {
        #expect(Renderer.render(Fixture.sdk("drawer")).isDrawerOnly)
        #expect(!Renderer.render(Fixture.sdk("t-plain") + Fixture.sdk("drawer")).isDrawerOnly)   // paper and a kick
        #expect(!Renderer.render(Fixture.sdk("t-plain")).isDrawerOnly)
        #expect(!Renderer.render(Fixture.data("protocol/job-prologue.bin")).isDrawerOnly)          // no kick
    }

    @Test func unknownCommandsBecomeWarnings() throws {
        let page = try #require(Renderer.render(hex("1b ff 41 0a")).first)
        #expect(page.warnings.count == 1)
    }

    @Test func textReceiptFixture() throws {
        let pages = Renderer.render(Fixture.sdk("receipt"))
        #expect(pages.count == 1)
        #expect(pages[0].cut == .partialAfterFeed)
        #expect(pages[0].bitmap.inkCount > 1_000)
    }
}
