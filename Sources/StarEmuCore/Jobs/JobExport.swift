import Foundation

/// Turns a job's pages into PNG files with predictable names.
public enum JobExport {
    public enum Mode: String, Sendable, CaseIterable, Codable {
        /// All pages on one strip, cuts marked with dashed lines.
        case stacked
        /// One file per page: `<base>-p1.png`, `<base>-p2.png`, …
        case separate
    }

    /// `receipt-20261016-140211` (local time).
    public static func baseName(for job: Job, prefix: String = "receipt") -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "\(prefix)-\(formatter.string(from: job.receivedAt))"
    }

    /// PNG files for the pages; pages without paper (e.g. drawer-only jobs) are skipped.
    public static func pngs(for pages: [Page], baseName: String, mode: Mode) throws -> [(name: String, data: Data)] {
        let printed = pages.filter { $0.bitmap.height > 0 }
        guard !printed.isEmpty else { return [] }
        switch mode {
        case .stacked:
            return [("\(baseName).png", try PNGExporter.png(PNGExporter.stacked(printed)))]
        case .separate where printed.count == 1:
            return [("\(baseName).png", try PNGExporter.png(printed[0].bitmap))]
        case .separate:
            return try printed.enumerated().map { index, page in
                ("\(baseName)-p\(index + 1).png", try PNGExporter.png(page.bitmap))
            }
        }
    }

    /// Writes the PNGs into `directory`, never overwriting: a clash gets ` 2`, ` 3`, … appended.
    @discardableResult
    public static func write(_ files: [(name: String, data: Data)], to directory: URL) throws -> [URL] {
        try files.map { file in
            let url = uniqueURL(for: file.name, in: directory)
            try file.data.write(to: url, options: .atomic)
            return url
        }
    }

    static func uniqueURL(for name: String, in directory: URL) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var url = directory.appendingPathComponent(name)
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(base) \(counter).\(ext)")
            counter += 1
        }
        return url
    }
}

extension JobStore {
    /// Stores bytes from a file the user opened (shown with remote `import: <name>`).
    @discardableResult
    public func importJob(_ data: Data, named name: String, at date: Date = Date()) throws -> Job {
        try save(data, meta: JobMeta(receivedAt: date, remote: "import: \(name)", localPort: 0))
    }

    public func deleteAll() throws {
        for job in try loadAll() { try delete(job) }
    }
}
