import Foundation

nonisolated enum TemperatureComponent: String, CaseIterable, Codable, Identifiable, Sendable {
    case batteryTemperature, socTemperature, chargerTemperature, wirelessCoilTemperature, hottestTemperature
    var id: Self { self }
    var title: LocalizedStringResource {
        switch self {
        case .batteryTemperature: "Battery temperature"
        case .socTemperature: "SoC temperature"
        case .chargerTemperature: "Charge IC temperature"
        case .wirelessCoilTemperature: "Wireless coil temperature"
        case .hottestTemperature: "Hottest component"
        }
    }
}

nonisolated struct TemperatureObservation: Sendable {
    let value: Double?
    let source: String?
}

nonisolated struct TemperatureHistoryRecord: Codable, Hashable, Sendable, Identifiable {
    let date: Date
    let values: [String: Double]
    let startsNewSegment: Bool
    let sourceBreaks: Set<String>?
    var id: Date { date }
    func value(_ component: TemperatureComponent) -> Double? {
        values[component.rawValue].flatMap { $0.isFinite && (-40...150).contains($0) ? $0 : nil }
    }
}

/// Recording is independent of charger state and of the island's enabled toggle.
/// Observe interruptions every tick, even if that tick is not stored on disk.
nonisolated struct TemperatureHistoryRecorder {
    static let retention: TimeInterval = 24 * 60 * 60
    static let limit = 20_000
    private(set) var records: [TemperatureHistoryRecord] = []
    private var previousDate: Date?
    private var previousSources: [TemperatureComponent: String] = [:]
    private var pendingBreaks: Set<String> = []
    private var newSegment = true

    mutating func breakContinuity() {
        newSegment = true
        previousDate = nil
        previousSources.removeAll(keepingCapacity: true)
    }

    @discardableResult
    mutating func observe(date: Date, readings: [TemperatureComponent: TemperatureObservation]) -> Bool {
        guard date.timeIntervalSince1970.isFinite else { breakContinuity(); return false }
        if let previousDate, date <= previousDate {
            // Never append duplicate or backwards timestamps. Subsequent forward
            // time starts a new segment, without rewriting already stored points.
            newSegment = true
            return false
        }
        if let previousDate, date.timeIntervalSince(previousDate) > 5 { newSegment = true }
        previousDate = date
        var values: [String: Double] = [:]
        for component in TemperatureComponent.allCases {
            guard let reading = readings[component], let value = reading.value,
                  value.isFinite, (-40...150).contains(value),
                  let source = reading.source, !source.isEmpty else {
                if previousSources.removeValue(forKey: component) != nil { pendingBreaks.insert(component.rawValue) }
                continue
            }
            if previousSources[component] != source { pendingBreaks.insert(component.rawValue) }
            previousSources[component] = source
            values[component.rawValue] = value
        }
        if let last = records.last, date.timeIntervalSince(last.date) < 5 { return false }
        // Do not fill a day-long file with empty frames on an unsupported device.
        if values.isEmpty && records.last?.values.isEmpty != false { return false }
        records.append(TemperatureHistoryRecord(date: date, values: values, startsNewSegment: newSegment,
                                               sourceBreaks: pendingBreaks.isEmpty ? nil : pendingBreaks))
        newSegment = false
        pendingBreaks.removeAll(keepingCapacity: true)
        trim(at: date)
        return true
    }

    mutating func mergeStored(_ stored: [TemperatureHistoryRecord], at date: Date) {
        let current = Set(records.map(\.date))
        records = (stored.filter { !current.contains($0.date) } + records).sorted { $0.date < $1.date }
        trim(at: date)
    }

    mutating func clear() {
        records.removeAll(keepingCapacity: true)
        pendingBreaks.removeAll(keepingCapacity: true)
        breakContinuity()
    }

    private mutating func trim(at date: Date) {
        let cutoff = date.addingTimeInterval(-Self.retention)
        if let count = records.firstIndex(where: { $0.date >= cutoff }), count > 0 { records.removeFirst(count) }
        else if records.last.map({ $0.date < cutoff }) == true { records.removeAll(keepingCapacity: true) }
        if records.count > Self.limit { records.removeFirst(records.count - Self.limit) }
    }
}

nonisolated enum TemperatureCurveRange: Int, CaseIterable, Identifiable, Sendable {
    case tenMinutes = 600, hour = 3600, sixHours = 21600, day = 86400
    var id: Self { self }
    var title: LocalizedStringResource {
        switch self {
        case .tenMinutes: "10 min"
        case .hour: "1 hour"
        case .sixHours: "6 hours"
        case .day: "24 hours"
        }
    }
}

nonisolated struct TemperatureCurvePoint: Identifiable, Hashable, Sendable {
    let date: Date
    let value: Double
    let component: TemperatureComponent
    let segment: Int
    var id: String { "\(component.rawValue):\(date.timeIntervalSince1970)" }
    var series: String { "\(component.rawValue):\(segment)" }
}

nonisolated struct TemperatureCurveSummary: Sendable {
    let minimum: Double
    let maximum: Double
    let first: Double
    let last: Double
    let count: Int
}

nonisolated struct TemperatureCurvePlot: Sendable {
    let points: [TemperatureCurvePoint]
    let singletons: [TemperatureCurvePoint]
    let records: [TemperatureHistoryRecord]
    let summaries: [TemperatureComponent: TemperatureCurveSummary]
    let domain: ClosedRange<Date>
    let temperatures: ClosedRange<Double>

    /// Binary-search actual frames. Do not snap a selection across a long gap.
    func nearest(to date: Date) -> TemperatureHistoryRecord? {
        var lower = 0, upper = records.count
        while lower < upper {
            let mid = (lower + upper) / 2
            if records[mid].date < date { lower = mid + 1 } else { upper = mid }
        }
        let candidates = [lower - 1, lower].filter { records.indices.contains($0) }
        guard let index = candidates.min(by: { abs(records[$0].date.timeIntervalSince(date))
            < abs(records[$1].date.timeIntervalSince(date)) }),
              abs(records[index].date.timeIntervalSince(date)) <= 5 else { return nil }
        return records[index]
    }

    static func make(records: [TemperatureHistoryRecord], component: TemperatureComponent,
                     range: TemperatureCurveRange, compare: Bool, now: Date = .now) -> Self {
        let end = records.last?.date ?? now
        let domain = end.addingTimeInterval(-Double(range.rawValue))...end.addingTimeInterval(1)
        let visible = records.filter { domain.contains($0.date) }
        let components = compare ? TemperatureComponent.allCases : [component]
        var points: [TemperatureCurvePoint] = []
        var summaries: [TemperatureComponent: TemperatureCurveSummary] = [:]
        for channel in components {
            var segment = 0
            var raw: [TemperatureCurvePoint] = []
            var previousDate: Date?
            for frame in visible {
                if frame.startsNewSegment || frame.sourceBreaks?.contains(channel.rawValue) == true
                    || previousDate.map({ frame.date.timeIntervalSince($0) > 10 }) == true { segment += 1 }
                previousDate = frame.date
                guard let value = frame.value(channel) else { segment += 1; continue }
                raw.append(TemperatureCurvePoint(date: frame.date, value: value, component: channel, segment: segment))
            }
            if let first = raw.first, let last = raw.last {
                var low = first.value, high = first.value
                for point in raw { low = min(low, point.value); high = max(high, point.value) }
                summaries[channel] = TemperatureCurveSummary(minimum: low,
                    maximum: high, first: first.value, last: last.value, count: raw.count)
            }
            points.append(contentsOf: reduce(raw, domain: domain))
        }
        var counts: [String: Int] = [:]
        for point in points { counts[point.series, default: 0] += 1 }
        let singletons = points.filter { counts[$0.series] == 1 }
        let temperatureDomain = ChartDomain.temperature(points.lazy.map(\.value),
            paddingFraction: 0.15, minimumPadding: 1, fallback: 20...45)
        return Self(points: points, singletons: singletons, records: visible, summaries: summaries,
                    domain: domain, temperatures: temperatureDomain)
    }

    private static func reduce(_ points: [TemperatureCurvePoint], domain: ClosedRange<Date>) -> [TemperatureCurvePoint] {
        guard points.count > 256 else { return points }
        let span = max(domain.upperBound.timeIntervalSince(domain.lowerBound), 1)
        var result: [TemperatureCurvePoint] = []
        var bucket: [TemperatureCurvePoint] = []
        var previousBucket: Int?
        func extremes(_ bucket: [TemperatureCurvePoint]) -> [TemperatureCurvePoint] {
            guard let first = bucket.first, let last = bucket.last,
                  let low = bucket.min(by: { $0.value < $1.value }),
                  let high = bucket.max(by: { $0.value < $1.value }) else { return [] }
            var seen: Set<Date> = []
            return [first, low, high, last].sorted { $0.date < $1.date }.filter { seen.insert($0.date).inserted }
        }
        for point in points {
            let index = min(47, max(0, Int(point.date.timeIntervalSince(domain.lowerBound) / span * 48)))
            if previousBucket != index || bucket.last?.segment != point.segment {
                result.append(contentsOf: extremes(bucket))
                bucket.removeAll(keepingCapacity: true)
            }
            previousBucket = index
            bucket.append(point)
        }
        result.append(contentsOf: extremes(bucket))
        guard result.count > 256 else { return result }
        // Pathological source churn: retain extrema/endpoints and bounded real
        // points, but make them singletons instead of inventing connecting lines.
        var keep: Set<Int> = [0, result.count - 1]
        if let low = result.indices.min(by: { result[$0].value < result[$1].value }) { keep.insert(low) }
        if let high = result.indices.max(by: { result[$0].value < result[$1].value }) { keep.insert(high) }
        for slot in 0..<252 { keep.insert(Int(Double(slot) / 251 * Double(result.count - 1))) }
        return keep.sorted().map { index in
            let point = result[index]
            return TemperatureCurvePoint(date: point.date, value: point.value, component: point.component, segment: index)
        }
    }
}
