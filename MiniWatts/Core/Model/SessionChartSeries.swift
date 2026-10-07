import Foundation

nonisolated struct SessionChartPoint: Identifiable, Hashable {
    let offset: TimeInterval
    let value: Double
    let series: String
    var id: TimeInterval { offset }
}

/// Missing observations separate series rather than connecting values across an
/// unknown interval. Time spacing alone is not evidence of missing measurements:
/// long sessions deliberately thin their recorded points.
nonisolated enum SessionChartSeries {
    static func points(
        _ samples: [ChargeSample],
        prefix: String,
        value: (ChargeSample) -> Double?
    ) -> [SessionChartPoint] {
        var segment = 0
        return samples.compactMap { sample in
            if sample.startsNewSegment == true { segment += 1 }
            guard let measured = value(sample), measured.isFinite else {
                segment += 1
                return nil
            }
            return SessionChartPoint(offset: sample.offset,
                                     value: measured,
                                     series: "\(prefix)-\(segment)")
        }
    }

    /// A line cannot show a segment with only one observation. Draw its point.
    static func singletonPoints(in points: [SessionChartPoint]) -> [SessionChartPoint] {
        var counts: [String: Int] = [:]
        for point in points { counts[point.series, default: 0] += 1 }
        return points.filter { counts[$0.series] == 1 }
    }

    /// Keep each bucket's peak separately for every continuous segment. A missing
    /// observation or explicit break inside a bucket must survive downsampling.
    static func sparklinePoints(_ samples: [ChargeSample], resolution: Int = 64) -> [SessionChartPoint] {
        let measured = points(samples, prefix: "input") { $0.inputWatts }
        guard measured.count > resolution, resolution > 0,
              let first = measured.first, let last = measured.last,
              last.offset > first.offset else { return measured }
        let span = last.offset - first.offset
        var result: [SessionChartPoint] = []
        var previousBucket: Int?
        for point in measured {
            let bucket = min(Int((point.offset - first.offset) / span * Double(resolution)), resolution - 1)
            if previousBucket == bucket, let previous = result.last, previous.series == point.series {
                if point.value > previous.value { result[result.count - 1] = point }
            } else {
                result.append(point)
                previousBucket = bucket
            }
        }
        return result
    }
}
