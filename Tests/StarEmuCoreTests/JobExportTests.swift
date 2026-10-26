import Foundation
import Testing
@testable import StarEmuCore

@Suite struct JobExportTests {
    private let twoPages = Renderer.render([
        .text(Data("1".utf8)), .lineFeed, .cut(.full), .text(Data("2".utf8)), .lineFeed, .cut(.partial),
    ])

    private func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func baseNameUsesLocalTimestamp() {
        var components = DateComponents()
        (components.year, components.month, components.day, components.hour, components.minute, components.second) = (2026, 10, 16, 14, 2, 11)
        let date = Calendar.current.date(from: components)!
        let job = Job(id: UUID(), receivedAt: date, remote: "x", localPort: 9100, byteCount: 1)
        #expect(JobExport.baseName(for: job) == "receipt-20261016-140211")
    }

    @Test func stackedIsOneFile() throws {
        let files = try JobExport.pngs(for: twoPages, baseName: "r", mode: .stacked)
        #expect(files.map(\.name) == ["r.png"])
    }

    @Test func separateNumbersPages() throws {
        let files = try JobExport.pngs(for: twoPages, baseName: "r", mode: .separate)
        #expect(files.map(\.name) == ["r-p1.png", "r-p2.png"])
        let single = try JobExport.pngs(for: [twoPages[0]], baseName: "r", mode: .separate)
        #expect(single.map(\.name) == ["r.png"])
    }

    @Test func drawerOnlyJobHasNothingToExport() throws {
        #expect(try JobExport.pngs(for: Renderer.render(Fixture.sdk("drawer")), baseName: "r", mode: .stacked).isEmpty)
    }

    @Test func writeNeverOverwrites() throws {
        let directory = try tempDirectory()
        let files = try JobExport.pngs(for: [twoPages[0]], baseName: "r", mode: .stacked)
        let first = try JobExport.write(files, to: directory)
        let second = try JobExport.write(files, to: directory)
        #expect(first.map(\.lastPathComponent) == ["r.png"])
        #expect(second.map(\.lastPathComponent) == ["r 2.png"])
    }

    @Test func importAndDeleteAll() throws {
        let store = try JobStore(directory: try tempDirectory())
        let job = try store.importJob(Fixture.sdk("t-plain"), named: "t-plain.bin")
        #expect(job.remote == "import: t-plain.bin")
        #expect(try store.loadAll() == [job])
        try store.deleteAll()
        #expect(try store.loadAll().isEmpty)
    }
}
