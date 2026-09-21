import Foundation

/// All mutable storage belongs to `queue`; producers never do disk I/O on the
/// sensor/main actor. Export is a queue barrier over all previously enqueued events.
nonisolated final class ProblemReportRecorder: @unchecked Sendable {
    static let shared = ProblemReportRecorder()
    static let segmentLimit = 256 * 1024
    private let queue = DispatchQueue(label: "MiniWatts.problem-reports", qos: .utility)
    private let directory: URL
    private let runID = UUID().uuidString
    private var storageError: String?
    private let formatter = ISO8601DateFormatter()

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("ProblemReports", isDirectory: true)
        queue.async { [self] in
            do {
                try prepareDirectory()
                // Persist the preceding run before starting a new one. No shutdown
                // callback is required, and a missing callback is not called a crash.
                let previous = try read("current-older.log") + read("current.log")
                if !previous.isEmpty {
                    try write(previous, to: file("previous.log"))
                }
                try write(Data(), to: file("current-older.log"))
                try write(Data(), to: file("current.log"))
                let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "test"
                let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "test"
                try append("lifecycle", "launch run=\(runID) version=\(version) build=\(build)", at: .now)
            } catch { storageError = String(describing: error) }
        }
    }

    func record(_ category: String, _ message: String) {
        let date = Date.now
        queue.async { [self] in
            do { try append(category, message, at: date) }
            catch { storageError = String(describing: error) }
        }
    }

    /// The UI only confirms a marker after it has reached the local file.
    func markIssue() async throws -> Date {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    let date = Date.now
                    try append("USER_MARK", "User marked a problem here", at: date)
                    continuation.resume(returning: date)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    struct Export: Sendable, Identifiable {
        let url: URL
        let preview: String
        var id: URL { url }
    }

    func export(summary: String, note: String) async throws -> Export {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    try prepareDirectory()
                    try append("report", "Report requested by user", at: .now)
                    let previous = String(decoding: try read("previous.log"), as: UTF8.self)
                    let current = String(decoding: try read("current-older.log") + read("current.log"), as: UTF8.self)
                    let text = """
                    MiniWatts problem report / 问题报告 · format 1
                    Generated (UTC): \(formatter.string(from: .now))
                    Run: \(runID)
                    Storage warning: \(storageError ?? "none")
                    Local records only; shared manually by the user.
                    A launch without a termination event does NOT prove a crash.
                    Logs are size-limited; the last events before termination may be absent.

                    # User description / 用户描述
                    \(note.prefix(2000))

                    # Current snapshot / 当前状态
                    \(summary.prefix(32000))

                    # Previous run / 上次运行
                    \(previous.isEmpty ? "No previous run recorded." : previous)

                    # Current run / 本次运行
                    \(current)
                    """
                    let exports = directory.appendingPathComponent("Exports", isDirectory: true)
                    try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
                    let stamp = formatter.string(from: .now).replacingOccurrences(of: ":", with: "-")
                    let url = exports.appendingPathComponent("MiniWatts-report-\(stamp)-\(UUID().uuidString.prefix(8)).txt")
                    try write(Data(text.utf8), to: url)
                    // Only our generated exports are eligible for pruning. Keep the
                    // newest three; never touch files saved via the share sheet.
                    let files = try FileManager.default.contentsOfDirectory(
                        at: exports, includingPropertiesForKeys: [.creationDateKey]
                    ).filter { $0.lastPathComponent.hasPrefix("MiniWatts-report-") && $0.pathExtension == "txt" }
                        .sorted { $0.lastPathComponent > $1.lastPathComponent }
                    for old in files.filter({ $0 != url }).dropFirst(2) {
                        try? FileManager.default.removeItem(at: old)
                    }
                    continuation.resume(returning: Export(url: url, preview: String(text.prefix(24000))))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func file(_ name: String) -> URL { directory.appendingPathComponent(name) }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    private func read(_ name: String) throws -> Data {
        let url = file(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return Data() }
        // Bound reads even if a prior version accidentally created an oversized log.
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let maximum = UInt64(Self.segmentLimit * 2)
        if size > maximum { try handle.seek(toOffset: size - maximum) }
        else { try handle.seek(toOffset: 0) }
        let data = try handle.readToEnd() ?? Data()
        if size > maximum, let newline = data.firstIndex(of: 10) {
            return Data(data[data.index(after: newline)...])
        }
        return data
    }

    private func write(_ data: Data, to url: URL) throws {
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
    }

    private func append(_ category: String, _ message: String, at date: Date) throws {
        let clean = message.prefix(600).replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        let data = Data("\(formatter.string(from: date)) [\(category.prefix(32))] \(clean)\n".utf8)
        let current = file("current.log")
        if !FileManager.default.fileExists(atPath: current.path) {
            try prepareDirectory()
            try write(Data(), to: current)
        }
        let size = (try FileManager.default.attributesOfItem(atPath: current.path)[.size] as? NSNumber)?.intValue ?? 0
        if size + data.count > Self.segmentLimit {
            try write(try read("current.log"), to: file("current-older.log"))
            try write(Data(), to: current)
        }
        let handle = try FileHandle(forWritingTo: current)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}
