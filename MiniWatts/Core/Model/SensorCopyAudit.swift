import Foundation

/// Diagnostic-only comparison with upstream's same-SMC-key averaging. It never
/// changes the measured values used for the dashboard, history, or glances.
nonisolated struct SensorCopyAudit {
    struct Comparison {
        let key: String
        let kind: HIDSensors.Kind
        let copies: [HIDSensors.Reading]
        let average: Double
    }

    private struct Identity: Hashable {
        let key: String
        let kind: HIDSensors.Kind
    }

    let comparisons: [Comparison]

    init(readings: [HIDSensors.Reading]) {
        let candidates = readings.filter { !$0.key.isEmpty && $0.value.isFinite }
        let groups = Dictionary(grouping: candidates) { Identity(key: $0.key, kind: $0.kind) }
        comparisons = groups.compactMap { identity, copies in
            guard copies.count > 1 else { return nil }
            let average = copies.reduce(0.0) { $0 + $1.value } / Double(copies.count)
            guard average.isFinite else { return nil }
            return Comparison(key: identity.key, kind: identity.kind, copies: copies, average: average)
        }.sorted { ($0.key, $0.kind.rawValue) < ($1.key, $1.kind.rawValue) }
    }

    /// USB port product from the two averaged candidate rails, for comparison
    /// only. It is neither a calibrated measurement nor a correction for a
    /// missing charging path.
    var candidateUSBWatts: Double? {
        guard let voltage = comparisons.first(where: { $0.key == "VQ0u" && $0.kind == .voltage })?.average,
              let current = comparisons.first(where: { $0.key == "IQ0u" && $0.kind == .current })?.average,
              voltage > 0.5 else { return nil }
        let power = voltage * abs(current)
        return power.isFinite ? power : nil
    }
}
