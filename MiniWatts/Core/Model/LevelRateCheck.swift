import Foundation

/// Compares a coarse system level change with measured cell energy over the same
/// interval. This diagnostic is not a live wattmeter or a correction factor.
nonisolated struct LevelRateCheck: Sendable, Equatable {
    let levelWatts: Double
    let cellWatts: Double
    let percentRise: Int
    let seconds: TimeInterval
    let packWattHours: Double
    var ratio: Double { levelWatts / cellWatts }
    var isLow: Bool { ratio >= 1.6 }
    var agrees: Bool { (0.7...1.3).contains(ratio) }
}

nonisolated struct LevelRateTracker {
    private struct Point {
        let date: Date
        let percent: Int
        let energy: Double
        let seconds: Double
    }
    private var previous: (Date, Double)?
    private var points: [Point] = []
    private var energy = 0.0
    private var seconds = 0.0
    private(set) var result: LevelRateCheck?

    mutating func reset() {
        previous = nil; points.removeAll(); energy = 0; seconds = 0; result = nil
    }

    mutating func observe(date: Date, percent: Int?, watts: Double?, charging: Bool, pack: Double) {
        guard charging, let percent, (0...100).contains(percent),
              let watts, watts.isFinite, watts >= 0, pack.isFinite, pack > 0 else { reset(); return }
        if let old = previous {
            let interval = date.timeIntervalSince(old.0)
            if interval <= 0 || interval > 10 { reset() }
            else {
                energy += (old.1 + watts) * 0.5 * interval / 3600
                seconds += interval
            }
        }
        previous = (date, watts)
        if let last = points.last, percent < last.percent || date.timeIntervalSince(last.date) > 1800 { reset(); previous = (date, watts) }
        if points.last?.percent != percent {
            points.append(Point(date: date, percent: percent, energy: energy, seconds: seconds))
            if points.count > 8 { points.removeFirst() }
        }
        // The initial sample can arrive mid-percent; start from the first transition.
        guard points.count >= 3, let first = points.dropFirst().first, let last = points.last else { return }
        let span = last.date.timeIntervalSince(first.date)
        let rise = last.percent - first.percent
        let watched = last.seconds - first.seconds
        let measuredEnergy = last.energy - first.energy
        guard rise >= 3, span >= 90, watched >= span * 0.9, measuredEnergy > 0 else { return }
        let cell = measuredEnergy * 3600 / watched
        guard cell >= 1 else { return }
        result = LevelRateCheck(levelWatts: Double(rise) / 100 * pack * 3600 / span,
                                cellWatts: cell, percentRise: rise, seconds: span, packWattHours: pack)
    }
}
