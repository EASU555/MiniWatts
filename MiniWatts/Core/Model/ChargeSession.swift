import Foundation

/// One point on a session's charge curve.
nonisolated struct ChargeSample: Codable, Hashable, Identifiable {
    /// Seconds since the session started.
    let offset: TimeInterval
    let inputWatts: Double
    let batteryWatts: Double
    let percent: Int
    let batteryTemperature: Double?
    let hottestTemperature: Double?
    /// True while `ProcessInfo.thermalState` was `.serious` or `.critical`.
    let throttled: Bool

    var id: TimeInterval { offset }
}

/// Everything recorded between plugging in and unplugging.
nonisolated struct ChargeSession: Codable, Identifiable, Hashable {
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

/// Persists charge sessions as a single JSON file in Application Support.
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
    /// Sessions kept on disk; older ones are dropped oldest-first.
    private static let sessionLimit = 60
    /// Points kept per session. Longer sessions are halved in place as they grow.
    static let sampleLimit = 1_500
    /// Seconds between recorded points.
    static let sampleInterval: TimeInterval = 5

    private let url: URL
    private let queue = DispatchQueue(label: "org.zhaohe.MiniWatts.sessions", qos: .utility)
    /// Guarded by `queue`. Holds at most the newest pending write.
    private var pending: [ChargeSession]?

    init(filename: String = "charge-sessions.json") {
        let directory = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                      in: .userDomainMask,
                                                      appropriateFor: nil,
                                                      create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        url = directory.appendingPathComponent(filename)
    }

    /// Reads the file. Call this off the main thread — `loaded()` does that for you.
    private func read() -> [ChargeSession] {
        guard let data = try? Data(contentsOf: url),
              let sessions = try? JSONDecoder().decode([ChargeSession].self, from: data) else { return [] }
        return sessions.sorted { $0.start > $1.start }
    }

    func loaded() async -> [ChargeSession] {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.read()) }
        }
    }

    /// Queues a write and returns immediately.
    func save(_ sessions: [ChargeSession]) {
        queue.async {
            let hadPending = self.pending != nil
            self.pending = sessions
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
        let trimmed = Array(sessions.sorted { $0.start > $1.start }.prefix(Self.sessionLimit))
        guard let data = try? JSONEncoder().encode(trimmed) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func deleteAll() {
        queue.async {
            self.pending = nil
            try? FileManager.default.removeItem(at: self.url)
        }
    }
}
