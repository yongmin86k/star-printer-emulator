import Foundation

/// Metadata known when a job is finished, before it is stored.
public struct JobMeta: Sendable, Codable, Equatable {
    public var receivedAt: Date
    public var remote: String
    public var localPort: UInt16

    public init(receivedAt: Date, remote: String, localPort: UInt16) {
        self.receivedAt = receivedAt
        self.remote = remote
        self.localPort = localPort
    }
}

/// A finished print job. Raw bytes live next to the metadata as `<id>.bin`.
public struct Job: Identifiable, Sendable, Codable, Hashable {
    public let id: UUID
    public let receivedAt: Date
    public let remote: String
    public let localPort: UInt16
    public let byteCount: Int
}

/// Stores jobs as `<id>.bin` (raw bytes) + `<id>.json` (metadata) in one directory.
public struct JobStore: Sendable {
    public let directory: URL

    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("StarEmu/jobs", isDirectory: true)
    }

    public init(directory: URL = JobStore.defaultDirectory) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func rawURL(for job: Job) -> URL {
        directory.appendingPathComponent("\(job.id.uuidString).bin")
    }

    public func metaURL(for job: Job) -> URL {
        directory.appendingPathComponent("\(job.id.uuidString).json")
    }

    @discardableResult
    public func save(_ data: Data, meta: JobMeta) throws -> Job {
        let job = Job(
            id: UUID(),
            receivedAt: meta.receivedAt,
            remote: meta.remote,
            localPort: meta.localPort,
            byteCount: data.count
        )
        try data.write(to: rawURL(for: job), options: .atomic)
        // Metadata last: a job only "exists" once its .json is present.
        try JSONEncoder().encode(job).write(to: metaURL(for: job), options: .atomic)
        return job
    }

    /// All stored jobs, newest first. Unreadable metadata and jobs missing their .bin are skipped.
    public func loadAll() throws -> [Job] {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let decoder = JSONDecoder()
        let jobs = files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in (try? Data(contentsOf: url)).flatMap { try? decoder.decode(Job.self, from: $0) } }
            .filter { FileManager.default.fileExists(atPath: rawURL(for: $0).path) }
        return jobs.sorted { ($0.receivedAt, $0.id.uuidString) > ($1.receivedAt, $1.id.uuidString) }
    }

    public func data(for job: Job) throws -> Data {
        try Data(contentsOf: rawURL(for: job))
    }

    public func delete(_ job: Job) throws {
        for url in [metaURL(for: job), rawURL(for: job)] where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    public func purge(keepingLast count: Int) throws {
        for job in try loadAll().dropFirst(max(count, 0)) {
            try delete(job)
        }
    }
}
