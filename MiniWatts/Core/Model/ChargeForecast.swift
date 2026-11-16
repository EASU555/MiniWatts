import Foundation

/// Approximate charging time from observed system battery-level transitions.
/// The taper weights are adapted from MiniWatts upstream v1.7's ChargeForecast.
/// No sensor wattage or assumed pack capacity enters this estimate.
nonisolated struct ChargeForecast: Equatable, Sendable {
    let percent: Int
    let reachedAt: Date
    let step: Int
    let secondsPerUnit: Double
    let measuredRise: Int
    let measuredSpan: TimeInterval

    static let taperStart = 80

    private static func weight(_ percent: Int) -> Double {
        switch percent {
        case ..<80: 1
        case ..<90: 2
        case ..<95: 3
        default: 4.5
        }
    }

    private static func units(from start: Int, to end: Int) -> Double {
        guard end > start else { return 0 }
        return (start..<end).reduce(0) { $0 + weight($1) }
    }

    init?(levelChanges: [(date: Date, percent: Int)]) {
        guard levelChanges.count >= 2,
              levelChanges.allSatisfy({ (0...100).contains($0.percent) && $0.date.timeIntervalSince1970.isFinite }),
              let first = levelChanges.first, let last = levelChanges.last else { return nil }
        let pairs = zip(levelChanges, levelChanges.dropFirst())
        guard pairs.allSatisfy({ pair in pair.0.date < pair.1.date && pair.0.percent < pair.1.percent }) else { return nil }
        let span = last.date.timeIntervalSince(first.date)
        let units = Self.units(from: first.percent, to: last.percent)
        guard span > 0, span.isFinite, units > 0 else { return nil }
        self.percent = last.percent
        reachedAt = last.date
        step = zip(levelChanges, levelChanges.dropFirst()).map { pair in pair.1.percent - pair.0.percent }.min() ?? 1
        secondsPerUnit = span / units
        measuredRise = last.percent - first.percent
        measuredSpan = span
    }

    func secondsRemaining(to target: Int, from current: Int, at now: Date) -> TimeInterval? {
        guard (0...100).contains(current), (0...100).contains(target),
              now.timeIntervalSince1970.isFinite else { return nil }
        guard target > current else { return 0 }
        let whole = secondsPerUnit * Self.units(from: current, to: target)
        guard current == percent else { return whole }
        let beyondStep = secondsPerUnit * Self.units(from: min(current + step, target), to: target)
        return max(whole - max(now.timeIntervalSince(reachedAt), 0), beyondStep)
    }
}

/// Only actual observed changes count: the first sample lands somewhere inside
/// a percent and must not be treated as the moment it changed.
nonisolated struct ChargeForecastTracker {
    private static let maximumSampleGap: TimeInterval = 30
    private static let maximumTransitionAge: TimeInterval = 30 * 60
    private var previousDate: Date?
    private var previousPercent: Int?
    private var transitions: [(date: Date, percent: Int)] = []
    private(set) var result: ChargeForecast?

    mutating func reset() {
        previousDate = nil
        previousPercent = nil
        transitions.removeAll(keepingCapacity: true)
        result = nil
    }

    @discardableResult
    mutating func observe(date: Date, percent: Int?, connected: Bool?, charging: Bool) -> ChargeForecast? {
        guard date.timeIntervalSince1970.isFinite, let percent, (0...100).contains(percent),
              connected == true, charging else {
            reset()
            return nil
        }
        if let previousDate {
            let gap = date.timeIntervalSince(previousDate)
            if gap <= 0 || gap > Self.maximumSampleGap {
                reset()
            }
        }
        if let previousPercent, percent < previousPercent { reset() }
        if let last = transitions.last, date.timeIntervalSince(last.date) > Self.maximumTransitionAge {
            reset()
        }
        if let previousPercent, percent > previousPercent {
            transitions.append((date, percent))
            if transitions.count > 6 { transitions.removeFirst(transitions.count - 6) }
            result = ChargeForecast(levelChanges: transitions)
        }
        previousDate = date
        previousPercent = percent
        return result
    }
}
