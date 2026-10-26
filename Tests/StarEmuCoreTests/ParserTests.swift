import Foundation
import Testing
@testable import StarEmuCore

@Suite struct ParserTests {
    private let prefix: [Command] = [
        .intlCharset(0),
        .tabStops([8, 16, 24, 32, 40, 48, 56, 64, 72, 80, 88, 96, 104, 112, 120, 128]),
        .ignored("ESC GS )", hex("55 02 00 40 00")),
    ]
    private let textPreamble: [Command] = [
        .codePage(0x80), .charSpacing(0), .ignored("ESC s", hex("00 00")), .ignored("ESC t", hex("00 00")),
    ]

    static let singleFeatureCases: [(String, [Command])] = [
        ("t-bold", [Command.bold(true), .bold(false)]),
        ("t-center", [.alignment(.center), .alignment(.left)]),
        ("t-right", [.alignment(.right)]),
        ("t-mag2x3", [.magnify(width: 2, height: 3), .magnify(width: 1, height: 1)]),
        ("t-invert", [.invert(true), .invert(false)]),
        ("t-underline", [.underline(1), .underline(0)]),
        ("t-fontb", [.font(.b), .font(.a)]),
        ("t-linespace", [.linePitch(dots: 32)]),
        ("t-feedline", [.feedLines(3)]),
        ("t-feed", [.feedDots(80)]),
        ("t-cut-partial", [.cut(.partialAfterFeed)]),
        ("t-cut-full", [.cut(.fullAfterFeed)]),
        ("qr", [.qrModel(2), .qrLevel(1), .qrCellSize(6), .qrData(Data("https://example.com/r/123".utf8)), .qrPrint]),
        ("barcode", [.barcode(BarcodeSpec(symbology: 6, hri: 2, mode: 2, heightDots: 80, data: Data("123456".utf8)))]),
        ("drawer", [.drawerPulse(on: 0x14, off: 0x14), .drawerKick(channel: 1)]),
    ]

    @Test func plainDocumentExact() {
        let expected = prefix + textPreamble + [.text(Data("A".utf8)), .lineFeed, .tabStops([])]
        #expect(StarPRNTParser.parse(Fixture.sdk("t-plain")) == expected)
    }

    @Test(arguments: singleFeatureCases)
    func singleFeatureDocumentContains(name: String, expected: [Command]) {
        let commands = StarPRNTParser.parse(Fixture.sdk(name))
        for command in expected {
            #expect(commands.contains(command), "\(name) should contain \(command)")
        }
    }

    @Test(arguments: Fixture.sdkNames)
    func sdkFixtureHasNoUnknownBytes(name: String) {
        let problems = StarPRNTParser.parse(Fixture.sdk(name)).filter {
            switch $0 {
            case .unknown, .malformed: true
            default: false
            }
        }
        #expect(problems.isEmpty, "\(name): \(problems)")
    }

    @Test func fullWidthImageIsTwelveBandsOfEightRows() {
        let bands = StarPRNTParser.parse(Fixture.sdk("image")).compactMap { cmd -> RasterBand? in
            if case .raster(let band) = cmd { band } else { nil }
        }
        #expect(bands.count == 12)
        #expect(bands.allSatisfy { $0.widthBytes == 72 && $0.height == 8 && $0.bits.count == 576 })
    }

    @Test func narrowImageIsCenteredSingleBand() {
        let commands = StarPRNTParser.parse(Fixture.sdk("image-narrow"))
        #expect(commands.contains(.alignment(.center)))
        let bands = commands.compactMap { cmd -> RasterBand? in if case .raster(let b) = cmd { b } else { nil } }
        #expect(bands.map { "\($0.widthBytes)x\($0.height)" } == ["25x40"])
    }

    @Test func sessionFraming() {
        #expect(StarPRNTParser.parse(Fixture.data("protocol/job-prologue.bin"))
            == [.rasterMode(false), .documentControl(4), .clearETB, .statusRequest])
        #expect(StarPRNTParser.parse(Fixture.data("protocol/document-start.bin")) == [.documentControl(3)])
        #expect(StarPRNTParser.parse(Fixture.data("protocol/document-end.bin")) == [.etb, .documentControl(4)])
        #expect(StarPRNTParser.parse(hex("1b 1e 61 00 00")) == [.asb(enabled: false), .nul])
        #expect(StarPRNTParser.parse(Fixture.data("protocol/printer-info-request.bin")) == [.printerInfoRequest(0x31)])
        #expect(StarPRNTParser.parse(hex("1b 1d 29 49 03 00 33 00 00")) == [.printerInfoRequest(0x33)])
        #expect(StarPRNTParser.parse(hex("1b 1d 29 49 00 00")) == [.ignored("ESC GS )", hex("49 00 00"))])
    }

    @Test(arguments: ["receipt", "image", "qr", "barcode"])
    func byteAtATimeMatchesWhole(name: String) {
        let data = Fixture.sdk(name)
        var parser = StarPRNTParser()
        var commands: [Command] = []
        for byte in data { commands += parser.feed(Data([byte])) }
        commands += parser.finish()
        #expect(merged(commands) == merged(StarPRNTParser.parse(data)))
    }

    /// Every document the SDK sends to a TSP100IIIW (StarGraphic) is already understood.
    @Test(arguments: Fixture.sdkNames)
    func tsp100IIIWDocumentsHaveNoUnknownBytes(name: String) {
        let data = Fixture.data("sdk-tsp100iiiw/\(name).bin")
        let commands = StarPRNTParser.parse(data)
        #expect(!commands.contains { if case .unknown = $0 { true } else if case .malformed = $0 { true } else { false } })
        var parser = StarPRNTParser()
        var chunked: [Command] = []
        for byte in data { chunked += parser.feed(Data([byte])) }
        chunked += parser.finish()
        #expect(chunked == commands)
    }

    @Test func randomChunkingMatchesWhole() {
        var rng = SplitMix64(seed: 42)
        let data = Fixture.sdk("receipt") + Fixture.sdk("image-narrow")
        let whole = merged(StarPRNTParser.parse(data))
        for _ in 0..<50 {
            var parser = StarPRNTParser()
            var commands: [Command] = []
            var offset = 0
            while offset < data.count {
                let size = Int.random(in: 1...64, using: &rng)
                commands += parser.feed(data[offset..<min(offset + size, data.count)])
                offset += size
            }
            commands += parser.finish()
            #expect(merged(commands) == whole)
        }
    }

    @Test func unknownEscapeIsSkipped() {
        #expect(StarPRNTParser.parse(hex("1b ff 41 0a")) == [.unknown(hex("1b ff")), .text(Data("A".utf8)), .lineFeed])
        #expect(StarPRNTParser.parse(hex("1b 1d ee 41")) == [.unknown(hex("1b 1d ee")), .text(Data("A".utf8))])
    }

    @Test func truncatedCommandIsMalformedAtFinish() {
        var parser = StarPRNTParser()
        #expect(parser.feed(hex("1b 1d 53 01 48 00 08 00 00 ff ff")).isEmpty)
        let tail = parser.finish()
        #expect(tail.count == 1)
        guard case .malformed = tail.first else { Issue.record("expected malformed, got \(tail)"); return }
    }

    @Test func oversizedRasterIsRejectedAndParsingResumes() {
        let commands = StarPRNTParser.parse(hex("1b 1d 53 01 ff ff ff ff 00") + Data("OK\n".utf8))
        guard case .malformed = commands.first else { Issue.record("expected malformed, got \(commands)"); return }
        #expect(commands.dropFirst() == [.text(Data("OK".utf8)), .lineFeed])
    }

    @Test func starRasterModeAsUsedByOlderSDKs() {
        let commands = StarPRNTParser.parse(hex("1b 2a 72 41  1b 2a 72 50 30 00  62 02 00 ff 00  1b 2a 72 42  41"))
        #expect(commands == [
            .rasterMode(true), .rasterModeSetting(0x50, "0"), .rasterLine(hex("ff 00")), .rasterMode(false), .text(Data("A".utf8)),
        ])
    }

    @Test func fuzzNeverCrashesOrStalls() {
        var rng = SplitMix64(seed: 7)
        let interesting: [UInt8] = [0x1B, 0x1D, 0x1E, 0x2A, 0x72, 0x53, 0x79, 0x44, 0x62, 0x00, 0x0A, 0x17]
        for _ in 0..<2_000 {
            let length = Int.random(in: 0...200, using: &rng)
            let bytes = (0..<length).map { _ in
                Bool.random(using: &rng) ? interesting.randomElement(using: &rng)! : UInt8.random(in: 0...255, using: &rng)
            }
            var parser = StarPRNTParser()
            _ = parser.feed(Data(bytes))
            _ = parser.finish()
        }
    }

    /// Text runs may be split differently by chunking; join adjacent runs before comparing.
    private func merged(_ commands: [Command]) -> [Command] {
        commands.reduce(into: []) { result, command in
            if case .text(let next) = command, case .text(let previous)? = result.last {
                result[result.count - 1] = .text(previous + next)
            } else {
                result.append(command)
            }
        }
    }
}
