import Foundation

/// Describes repeated gas-gauge readings without deciding that any one of them
/// is wrong. The displayed battery-area temperature remains the hottest sensor;
/// the median and range are evidence for checking a new device model.
nonisolated struct BatteryGaugeSummary: Equatable, Sendable {
    let count: Int
    let minimum: Double
    let median: Double
    let maximum: Double

    init?(values: [Double]) {
        let sorted = values.filter(\.isFinite).sorted()
        guard sorted.count >= 2, let minimum = sorted.first,
              let maximum = sorted.last else { return nil }
        count = sorted.count
        self.minimum = minimum
        self.maximum = maximum
        let middle = sorted.count / 2
        median = sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }

    var spread: Double { maximum - minimum }
}
