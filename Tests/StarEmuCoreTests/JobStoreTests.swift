import Foundation
import Testing
@testable import StarEmuCore

@Suite struct JobStoreTests {
    let directory: URL
    let store: JobStore

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("staremu-tests-\(UUID().uuidString)", isDirectory: true)
        store = try JobStore(directory: directory)
    }

    private func meta(_ seconds: TimeInterval, remote: String = "10.0.0.2:5000") -> JobMeta {
        JobMeta(receivedAt: Date(timeIntervalSince1970: seconds), remote: remote, localPort: 9100)
    }

    @Test func roundTrip() throws {
        let bytes = Data([0x1B, 0x40, 0x41, 0x0A])
        let job = try store.save(bytes, meta: meta(1_000))

        #expect(job.byteCount == 4)
        #expect(job.remote == "10.0.0.2:5000")
        #expect(job.localPort == 9100)
        #expect(try store.loadAll() == [job])
        #expect(try store.data(for: job) == bytes)
    }

    @Test func loadAllIsNewestFirst() throws {
        let old = try store.save(Data([1]), meta: meta(1_000))
        let new = try store.save(Data([2]), meta: meta(2_000))
        let mid = try store.save(Data([3]), meta: meta(1_500))

        #expect(try store.loadAll().map(\.id) == [new.id, mid.id, old.id])
    }

    @Test func deleteRemovesBothFiles() throws {
        let job = try store.save(Data([1, 2, 3]), meta: meta(1_000))
        try store.delete(job)

        #expect(try store.loadAll().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.rawURL(for: job).path))
        #expect(!FileManager.default.fileExists(atPath: store.metaURL(for: job).path))
    }

    @Test func purgeKeepsNewest() throws {
        let jobs = try (0..<5).map { try store.save(Data([UInt8($0)]), meta: meta(Double(1_000 + $0))) }
        try store.purge(keepingLast: 2)

        #expect(try store.loadAll().map(\.id) == [jobs[4].id, jobs[3].id])
    }

    @Test func ignoresStrayFiles() throws {
        try Data("junk".utf8).write(to: directory.appendingPathComponent("notes.txt"))
        try Data("{".utf8).write(to: directory.appendingPathComponent("broken.json"))
        let job = try store.save(Data([9]), meta: meta(1_000))

        #expect(try store.loadAll() == [job])
    }
}
