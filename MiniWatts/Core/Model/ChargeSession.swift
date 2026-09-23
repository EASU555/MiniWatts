import Foundation

/// One point on a session's charge curve.
nonisolated struct ChargeSample: Codable, Hashable, Identifiable, Sendable {
    /// Seconds since the session started.
    let offset: TimeInterval
    /// Nil means the corresponding private sensor did not report. It must remain
    /// distinct from a measured zero so charts can show a gap instead of a false
    /// power dropout.
    let inputWatts: Double?
    let batteryWatts: Double?
    let percent: Int
    let batteryTemperature: Double?
    let hottestTemperature: Double?
    /// True while `ProcessInfo.thermalState` was `.serious` or `.critical`.
    let throttled: Bool

    var id: TimeInterval { offset }
}

/// Everything recorded between plugging in and unplugging.
nonisolated struct ChargeSession: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let start: Date
    var end: Date?
    var startPercent: Int
    var endPercent: Int
    var totals: EnergyTotals
    var samples: [ChargeSample]
    var peakInputWatts: Double
    var peakBatteryWatts: Double
    var peakBatteryTemperature: Double?
    var adapterName: String?
    var adapterRatedWatts: Double?
    var isWireless: Bool
    /// Seconds spent with the system thermally throttling.
    var throttledSeconds: TimeInterval

    var isOpen: Bool { end == nil }
    var duration: TimeInterval { (end ?? .now).timeIntervalSince(start) }
    var gainedPercent: Int { max(endPercent - startPercent, 0) }

    /// Copy to fall back to when the adapter never identified itself. The adapter's
    /// own name is hardware and is shown verbatim; this is the only half that is
    /// translated, so the two are kept apart rather than merged into one `String`.
    var fallbackTitle: LocalizedStringResource {
        isWireless ? "Wireless charger" : "Unknown adapter"
    }

    /// Share of the session spent under thermal throttling, 0…1.
    var throttledFraction: Double {
        guard duration > 0 else { return 0 }
        return min(throttledSeconds / duration, 1)
    }

    init(start: Date, startPercent: Int, adapterName: String?, adapterRatedWatts: Double?, isWireless: Bool) {
        self.id = UUID()
        self.start = start
        self.end = nil
        self.startPercent = startPercent
        self.endPercent = startPercent
        self.totals = EnergyTotals()
        self.samples = []
        self.peakInputWatts = 0
        self.peakBatteryWatts = 0
        self.peakBatteryTemperature = nil
        self.adapterName = adapterName
        self.adapterRatedWatts = adapterRatedWatts
        self.isWireless = isWireless
        self.throttledSeconds = 0
    }
}

/// Persists charge sessions and a recoverable copy in Application Support.
///
/// Encoding and writing happen on a background queue. They used to happen inline on
/// whatever thread called: at the ceiling of 60 sessions × 1,500 samples the file is
/// several megabytes, so the periodic save during a charge was a multi-hundred
/// millisecond stall on the main thread every thirty seconds, and the load in
/// `PowerMonitor.init` was the same stall before the first frame.
///
/// Writes are coalesced: a save issued while one is already queued replaces it, so a
/// burst of calls costs one encode.
/// `@unchecked Sendable` because the checker cannot see the confinement: every
/// mutable member (`pending`) is touched only from inside `queue`, which is serial,
/// and `url` is a `let`.
nonisolated final class SessionStore: @unchecked Sendable {
    enum LoadResult: Sendable {
        case loaded([ChargeSession])
        case recovered([ChargeSession], reason: String)
        case failed(String)
    }

    enum SaveResult: Sendable {
        case saved
        case backupFailed(String)
        case failed(String)
    }

    /// Sessions kept on disk; older ones are dropped oldest-first.
    private static let sessionLimit = 60
    /// Points kept per session. Longer sessions are halved in place as they grow.
    static let sampleLimit = 1_500
    /// Seconds between recorded points.
    static let sampleInterval: TimeInterval = 5

    private let url: URL
    private let backupURL: URL
    private let queue = DispatchQueue(label: "org.zhaohe.MiniWatts.sessions", qos: .utility)
    /// Guarded by `queue`. Holds at most the newest pending write.
    private var pending: [ChargeSession]?
    private var pendingCompletions: [@Sendable (SaveResult) -> Void] = []

    init(filename: String = "charge-sessions.json", directory: URL? = nil) {
        // A temporary-directory fallback would make a failed Application Support
        // lookup look like a successful but permanently lost history.
        let directory = directory ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        url = directory.appendingPathComponent(filename)
        backupURL = directory.appendingPathComponent(filename + ".backup")
    }

    /// Missing is an empty first run; unreadable or invalid is never empty history.
    private func readFile(_ file: URL) throws -> [ChargeSession]? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let data = try Data(contentsOf: file)
        return try JSONDecoder().decode([ChargeSession].self, from: data)
    }

    private func failureCode(_ error: Error) -> String {
        let value = error as NSError
        // Avoid placing the app-container path or other local details in a
        // shareable problem report. Domain and code identify the failure class.
        return "\(value.domain)(\(value.code))"
    }

    private func read() -> LoadResult {
        do {
            if let sessions = try readFile(url) {
                return .loaded(sessions.sorted { $0.start > $1.start })
            }
        } catch {
            let primaryError = "primary: \(failureCode(error))"
            do {
                if let backup = try readFile(backupURL) {
                    return .recovered(backup.sorted { $0.start > $1.start }, reason: primaryError)
                }
                return .failed(primaryError + "; backup missing")
            } catch {
                return .failed(primaryError + "; backup: \(failureCode(error))")
            }
        }
        do {
            if let backup = try readFile(backupURL) {
                return .recovered(backup.sorted { $0.start > $1.start }, reason: "primary missing")
            }
            return .loaded([])
        } catch {
            return .failed("primary missing; backup: \(failureCode(error))")
        }
    }

    func loaded() async -> LoadResult {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.read()) }
        }
    }

    /// Queues a write and returns immediately.
    func save(_ sessions: [ChargeSession], completion: @escaping @Sendable (SaveResult) -> Void) {
        queue.async {
            let hadPending = self.pending != nil
            self.pending = sessions
            self.pendingCompletions.append(completion)
            // One drain task per burst: if a write is already queued behind us it
            // will pick up whatever `pending` holds by the time it runs.
            guard !hadPending else { return }
            self.queue.async { self.drain() }
        }
    }

    /// Must run on `queue`.
    private func drain() {
        guard let sessions = pending else { return }
        pending = nil
        let completions = pendingCompletions
        pendingCompletions = []
        let trimmed = Array(sessions.sorted { $0.start > $1.start }.prefix(Self.sessionLimit))
        let result: SaveResult
        do {
            let data = try JSONEncoder().encode(trimmed)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            // Write the primary first. If this succeeds and the second write
            // fails, the newest history is still readable on next launch.
            try data.write(to: url, options: .atomic)
            do {
                try data.write(to: backupURL, options: .atomic)
                result = .saved
            } catch {
                result = .backupFailed(failureCode(error))
            }
        } catch {
            result = .failed(failureCode(error))
        }
        completions.forEach { $0(result) }
    }
}
