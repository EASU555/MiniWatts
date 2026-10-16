import Foundation

nonisolated final class TemperatureHistoryStore: @unchecked Sendable {
    enum LoadResult: Sendable {
        case loaded([TemperatureHistoryRecord])
        case recovered([TemperatureHistoryRecord], reason: String)
        case failed(String)
    }
    enum SaveResult: Sendable { case saved, backupFailed(String), failed(String) }
    private struct Header: Codable {
        let version: Int
        let compactedAt: Date
    }
    private struct Archive { let header: Header; let records: [TemperatureHistoryRecord] }
    private enum Invalid: Error { case version, size, record }
    private let url: URL
    private let backupURL: URL
    private let queue = DispatchQueue(label: "org.zhaohe.MiniWatts.temperatures", qos: .utility)
    // Accessed only on queue. Append new frames rather than rewriting 24 hours
    // every thirty seconds. Expired disk frames are compacted at most hourly.
    private var needsRewrite = true
    private var lastWrittenAt: Date?
    private var firstWrittenAt: Date?
    private var lastCompaction = Date.distantPast
    private var storedCount = 0

    init(directory: URL? = nil) {
        let directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        url = directory.appendingPathComponent("temperature-history-v1.json")
        backupURL = directory.appendingPathComponent("temperature-history-v1.json.backup")
    }

    private func code(_ error: Error) -> String {
        let error = error as NSError
        return "\(error.domain)(\(error.code))"
    }

    private func read(_ file: URL) throws -> Archive? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 12 * 1024 * 1024 else { throw Invalid.size }
        let data = try Data(contentsOf: file)
        // A torn append is not silently accepted as a complete history. The
        // independently flushed safety copy supplies the last complete batch.
        guard data.last == 10 else { throw Invalid.record }
        let lines = data.split(separator: 10)
        guard let first = lines.first else { throw Invalid.record }
        let decoder = JSONDecoder()
        let header = try decoder.decode(Header.self, from: Data(first))
        guard header.version == 1 else { throw Invalid.version }
        guard lines.count - 1 <= TemperatureHistoryRecorder.limit else { throw Invalid.size }
        let records = try lines.dropFirst().map { try decoder.decode(TemperatureHistoryRecord.self, from: Data($0)) }
        var previous: Date?
        for record in records {
            guard record.date.timeIntervalSince1970.isFinite,
                  previous.map({ record.date > $0 }) ?? true,
                  record.values.allSatisfy({ TemperatureComponent(rawValue: $0.key) != nil
                      && $0.value.isFinite && (-40...150).contains($0.value) }),
                  record.sourceBreaks?.allSatisfy({ TemperatureComponent(rawValue: $0) != nil }) ?? true
            else { throw Invalid.record }
            previous = record.date
        }
        return Archive(header: header, records: records)
    }

    private func adopt(_ archive: Archive, needsRewrite: Bool) {
        self.needsRewrite = needsRewrite
        lastWrittenAt = archive.records.last?.date
        firstWrittenAt = archive.records.first?.date
        storedCount = archive.records.count
        lastCompaction = archive.header.compactedAt
    }

    private func load() -> LoadResult {
        var primaryFailure: String?
        do {
            if let archive = try read(url) {
                let backup = try? read(backupURL)
                let healthy = backup?.records.count == archive.records.count
                    && backup?.records.last?.date == archive.records.last?.date
                adopt(archive, needsRewrite: !healthy)
                return .loaded(archive.records)
            }
        } catch { primaryFailure = "primary: " + code(error) }
        do {
            if let archive = try read(backupURL) {
                adopt(archive, needsRewrite: true)
                return .recovered(archive.records, reason: primaryFailure ?? "primary missing")
            }
        } catch { return .failed((primaryFailure ?? "primary missing") + "; backup: " + code(error)) }
        return primaryFailure.map { .failed($0 + "; backup missing") } ?? .loaded([])
    }

    func loaded() async -> LoadResult {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.load()) }
        }
    }

    private func lines(_ records: [TemperatureHistoryRecord]) throws -> Data {
        let encoder = JSONEncoder()
        var data = Data()
        for record in records {
            data.append(try encoder.encode(record))
            data.append(10)
        }
        return data
    }

    private func append(_ data: Data, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    /// Primary then safety-copy incremental checkpoints, each flushed before the
    /// next. Only initial creation, recovery, clear and hourly compaction rewrite
    /// complete files atomically. No work runs on the one-second UI/sensor actor.
    func save(_ records: [TemperatureHistoryRecord]) async -> SaveResult {
        await withCheckedContinuation { continuation in
            queue.async {
                let result: SaveResult
                do {
                    guard records.count <= TemperatureHistoryRecorder.limit else { throw Invalid.size }
                    let additions = records.filter { record in self.lastWrittenAt.map { record.date > $0 } ?? true }
                    let expired = self.firstWrittenAt.map { first in records.first.map { first < $0.date } ?? true } ?? false
                    let rewrite = self.needsRewrite || records.isEmpty
                        || self.storedCount + additions.count > TemperatureHistoryRecorder.limit
                        || (expired && Date.now.timeIntervalSince(self.lastCompaction) >= 3600)
                    let data: Data
                    let compactedAt = Date.now
                    if rewrite {
                        var full = try JSONEncoder().encode(Header(version: 1, compactedAt: compactedAt))
                        full.append(10)
                        full.append(try self.lines(records))
                        data = full
                        try FileManager.default.createDirectory(at: self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try data.write(to: self.url, options: .atomic)
                    } else {
                        data = try self.lines(additions)
                        if !data.isEmpty { try self.append(data, to: self.url) }
                    }
                    do {
                        if rewrite {
                            try data.write(to: self.backupURL, options: .atomic)
                            self.firstWrittenAt = records.first?.date
                            self.storedCount = records.count
                            self.lastCompaction = compactedAt
                        } else {
                            if !data.isEmpty { try self.append(data, to: self.backupURL) }
                            self.storedCount += additions.count
                        }
                        self.lastWrittenAt = records.last?.date
                        self.needsRewrite = false
                        result = .saved
                    } catch {
                        self.needsRewrite = true
                        result = .backupFailed(self.code(error))
                    }
                } catch {
                    self.needsRewrite = true
                    result = .failed(self.code(error))
                }
                continuation.resume(returning: result)
            }
        }
    }
}
