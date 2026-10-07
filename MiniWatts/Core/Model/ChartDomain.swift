import Foundation

/// Streaming domain reductions: do not allocate intermediate value arrays or
/// repeat a whole-history scan for each mark in a chart.
nonisolated enum ChartDomain {
    static func powerCeiling<S: Sequence>(
        _ samples: S,
        headroom: Double,
        readings: (S.Element) -> (Double?, Double?)
    ) -> Double {
        var peak = 0.0
        for sample in samples {
            let (input, battery) = readings(sample)
            if let input, input.isFinite { peak = max(peak, input) }
            if let battery, battery.isFinite { peak = max(peak, battery) }
        }
        return max(peak * headroom, 5)
    }

    static func temperature<S: Sequence>(
        _ values: S,
        paddingFraction: Double,
        minimumPadding: Double,
        fallback: ClosedRange<Double>
    ) -> ClosedRange<Double> where S.Element == Double {
        var low: Double?
        var high: Double?
        for value in values where value.isFinite {
            low = min(low ?? value, value)
            high = max(high ?? value, value)
        }
        guard let low, let high else { return fallback }
        let padding = max((high - low) * paddingFraction, minimumPadding)
        return (low - padding)...(high + padding)
    }
}
