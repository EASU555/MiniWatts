import Foundation

/// A bounded least-squares trend, not an instantaneous temperature derivative.
/// A minute of observations is required; missing readings, source changes and
/// sampling gaps must never masquerade as a fast rise or fall on resumption.
nonisolated struct TemperatureTrendWindow {
    private struct Point {
        let date: Date
        let value: Double
    }

    private var points: [Point] = []
    private var source: String?
    private(set) var rate: Double?

    mutating func reset() {
        points.removeAll(keepingCapacity: true)
        source = nil
        rate = nil
    }

    @discardableResult
    mutating func add(date: Date, value: Double?, source: String?) -> Double? {
        guard date.timeIntervalSince1970.isFinite,
              let value, value.isFinite, (-40...150).contains(value),
              let source, !source.isEmpty else {
            reset()
            return nil
        }
        if let last = points.last {
            let interval = date.timeIntervalSince(last.date)
            if self.source != source || interval < 0 || interval > 5 { reset() }
            else if interval == 0 { return rate }
        }
        self.source = source
        points.append(Point(date: date, value: value))
        points.removeAll { date.timeIntervalSince($0.date) > 120 }
        if points.count > 180 { points.removeFirst(points.count - 180) }
        guard let first = points.first, points.count >= 13,
              date.timeIntervalSince(first.date) >= 60 else {
            rate = nil
            return nil
        }
        let count = Double(points.count)
        var sumX = 0.0, sumY = 0.0, sumXX = 0.0, sumXY = 0.0
        for point in points {
            let x = point.date.timeIntervalSince(first.date)
            sumX += x
            sumY += point.value
            sumXX += x * x
            sumXY += x * point.value
        }
        let denominator = count * sumXX - sumX * sumX
        guard denominator > 0 else { rate = nil; return nil }
        let slope = (count * sumXY - sumX * sumY) / denominator * 60
        rate = slope.isFinite ? slope : nil
        return rate
    }
}
