import Foundation

/// Bounded, ordered trace storage. Formatting is deliberately separate from
/// collection so a one-second producer only retains immutable numeric values.
nonisolated enum MonitoringTrace {
    static func append<Value>(_ value: Value, to records: inout [Value], limit: Int) {
        records.append(value)
        if records.count > limit { records.removeFirst(records.count - limit) }
    }

    static func epoch(_ date: Date) -> String {
        String(format: "%.3f", date.timeIntervalSince1970)
    }
}

nonisolated struct SampleTimingTrace: Sendable {
    let tick: Int
    let startedAt: Date
    let cpuSampledAt: Date
    let cpuIntervalSeconds: TimeInterval?
    let finishedAt: Date
    let publishedAt: Date
    let elapsedMilliseconds: Double
    let cpuUsagePercent: Double?

    var formatted: String {
        let interval: String = cpuIntervalSeconds.map { String(format: "%.2f", $0) } ?? "—"
        let cpu: String = cpuUsagePercent.map { String(format: "%.1f", $0) } ?? "nil"
        let fields: [String] = [
            "tick=\(tick)",
            "start=\(MonitoringTrace.epoch(startedAt))",
            "cpuAt=\(MonitoringTrace.epoch(cpuSampledAt))",
            "cpuWindow=\(interval)s",
            "finish=\(MonitoringTrace.epoch(finishedAt))",
            "publish=\(MonitoringTrace.epoch(publishedAt))",
            "probeMs=\(String(format: "%.0f", elapsedMilliseconds))",
            "cpu=\(cpu)"
        ]
        return fields.joined(separator: " ")
    }
}

nonisolated struct ActivityTimingTrace: Sendable {
    let sampledAt: Date?
    let enqueuedAt: Date
    let startedAt: Date
    let finishedAt: Date
    let returned: Bool

    var queueMilliseconds: Double { startedAt.timeIntervalSince(enqueuedAt) * 1_000 }
    var activityMilliseconds: Double { finishedAt.timeIntervalSince(startedAt) * 1_000 }

    var formatted: String {
        let sample: String = sampledAt.map(MonitoringTrace.epoch) ?? "nil"
        let age: String = sampledAt.map {
            String(format: "%.0f", finishedAt.timeIntervalSince($0) * 1_000)
        } ?? "nil"
        let fields: [String] = [
            "sample=\(sample)",
            "enqueue=\(MonitoringTrace.epoch(enqueuedAt))",
            "start=\(MonitoringTrace.epoch(startedAt))",
            "return=\(MonitoringTrace.epoch(finishedAt))",
            "queueMs=\(String(format: "%.0f", queueMilliseconds))",
            "activityMs=\(String(format: "%.0f", activityMilliseconds))",
            "sampleAgeMs=\(age)",
            "result=\(returned ? "returned" : "timeout")"
        ]
        return fields.joined(separator: " ")
    }
}

nonisolated struct ElectricalEvidenceTrace: Sendable {
    nonisolated struct IndexedValue: Equatable, Sendable {
        let index: Int
        let value: Double
    }

    let date: Date
    let isCharging: Bool
    let inputWatts: Double?
    let batteryWatts: Double?
    let shownWatts: Double?
    let shownIsBatterySide: Bool
    let thermalState: Int
    private(set) var voltage: [IndexedValue] = []
    private(set) var current: [IndexedValue] = []
    private(set) var unidentifiedQ: [IndexedValue] = []
    private(set) var unidentifiedW: [IndexedValue] = []
    private(set) var batteryGauge: [IndexedValue] = []

    init(date: Date, isCharging: Bool, inputWatts: Double?, batteryWatts: Double?,
         shownWatts: Double?, shownIsBatterySide: Bool, thermalState: Int) {
        self.date = date
        self.isCharging = isCharging
        self.inputWatts = inputWatts
        self.batteryWatts = batteryWatts
        self.shownWatts = shownWatts
        self.shownIsBatterySide = shownIsBatterySide
        self.thermalState = thermalState
    }

    /// Call once for each sensor in enumeration order. Keep duplicate services,
    /// exact names and indices intact without rescanning the array per rail.
    mutating func capture(name: String, index: Int, value: Double) {
        switch name {
        case "Charger VQ0u": voltage.append(IndexedValue(index: index, value: value))
        case "Charger IQ0u": current.append(IndexedValue(index: index, value: value))
        case "Charger QQ0u": unidentifiedQ.append(IndexedValue(index: index, value: value))
        case "Charger WQ0u": unidentifiedW.append(IndexedValue(index: index, value: value))
        case "gas gauge battery": batteryGauge.append(IndexedValue(index: index, value: value))
        default: break
        }
    }

    private static func values(_ readings: [IndexedValue]) -> String {
        guard !readings.isEmpty else { return "—" }
        return readings.map { "\($0.index):\(String(format: "%.3f", $0.value))" }
            .joined(separator: ",")
    }

    var formatted: String {
        let input: String = inputWatts.map { String(format: "%.2f", $0) } ?? "—"
        let battery: String = batteryWatts.map { String(format: "%.2f", $0) } ?? "—"
        let shown: String = shownWatts.map { String(format: "%.2f", $0) } ?? "—"
        let fields: [String] = [
            "t=\(MonitoringTrace.epoch(date))",
            "charge=\(isCharging)",
            "inputW=\(input)",
            "batteryW=\(battery)",
            "shown=\(shown)",
            "shownSide=\(shownIsBatterySide ? "battery" : "input")",
            "VQ0u=[\(Self.values(voltage))]",
            "IQ0u=[\(Self.values(current))]",
            "QQ0u=[\(Self.values(unidentifiedQ))]",
            "WQ0u=[\(Self.values(unidentifiedW))]",
            "gaugeC=[\(Self.values(batteryGauge))]",
            "thermal=\(thermalState)"
        ]
        return fields.joined(separator: " ")
    }
}

nonisolated struct BatteryLevelCandidates: Equatable, Sendable {
    let mobileGestaltPercent: Int?
    let powerSourcePercent: Int?
    let uiDevicePercent: Int?

    var formatted: String {
        let fields: [String] = [
            "MobileGestalt \(mobileGestaltPercent.map(String.init) ?? "—")",
            "powerd \(powerSourcePercent.map(String.init) ?? "—")",
            "UIDevice \(uiDevicePercent.map(String.init) ?? "—")"
        ]
        return fields.joined(separator: " · ")
    }
}
