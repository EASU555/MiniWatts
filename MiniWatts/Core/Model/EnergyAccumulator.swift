import Foundation

/// Energy totals for one stretch of charging, integrated from the live sensors.
///
/// The sandbox never hands out the pack's design capacity, but it does hand out
/// voltage and current at ~1 Hz on both sides of the charge IC. Integrating those
/// gives the two numbers that actually matter — how much energy the adapter
/// delivered, and how much of it reached the cell.
nonisolated struct EnergyTotals: Codable, Hashable {
    /// ∫ V·I dt at the adapter, in watt-hours.
    var inputWattHours: Double = 0
    /// ∫ V·I dt at the battery rail, in watt-hours.
    var batteryWattHours: Double = 0
    /// ∫ I dt at the battery rail, in milliamp-hours. Comparable to a pack's mAh rating.
    var batteryMilliAmpHours: Double = 0
    /// Seconds of integration, which is not the same as wall-clock time: gaps
    /// longer than the sample window are dropped rather than extrapolated.
    var integratedSeconds: TimeInterval = 0
    /// Valid coverage for each sensor channel. These differ when one private
    /// sensor temporarily disappears while the others continue reporting.
    var inputIntegratedSeconds: TimeInterval = 0
    var batteryIntegratedSeconds: TimeInterval = 0
    var batteryCurrentIntegratedSeconds: TimeInterval = 0

    /// Delivered energy, or nil when none could be measured.
    ///
    /// Wireless charging exposes no input-current sensor, so this stays at zero
    /// for a whole MagSafe session while the battery side accumulates normally.
    /// Nil says "not measured" where a bare 0.00 Wh would read as "nothing came in".
    var measuredInputWattHours: Double? {
        inputIntegratedSeconds > 0 ? inputWattHours : nil
    }

    var measuredBatteryWattHours: Double? {
        batteryIntegratedSeconds > 0 ? batteryWattHours : nil
    }

    var measuredBatteryMilliAmpHours: Double? {
        batteryCurrentIntegratedSeconds > 0 ? batteryMilliAmpHours : nil
    }

    /// Share of delivered energy that reached the cell, 0…100.
    var efficiencyPercent: Double? {
        guard inputWattHours > 0.001,
              batteryWattHours > 0,
              inputIntegratedSeconds > 0,
              batteryIntegratedSeconds > 0 else { return nil }
        let coverage = min(inputIntegratedSeconds, batteryIntegratedSeconds)
            / max(inputIntegratedSeconds, batteryIntegratedSeconds)
        // Comparing energy from materially different time windows would produce
        // a precise-looking but meaningless efficiency figure.
        guard coverage >= 0.9 else { return nil }
        return min(batteryWattHours / inputWattHours, 1) * 100
    }

    /// Energy that turned into heat in the cable, the charge IC and the coil.
    var lossWattHours: Double {
        max(inputWattHours - batteryWattHours, 0)
    }

    var measuredLossWattHours: Double? {
        efficiencyPercent == nil ? nil : lossWattHours
    }

    var averageInputWatts: Double? {
        guard inputIntegratedSeconds > 0 else { return nil }
        return inputWattHours * 3600 / inputIntegratedSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case inputWattHours
        case batteryWattHours
        case batteryMilliAmpHours
        case integratedSeconds
        case inputIntegratedSeconds
        case batteryIntegratedSeconds
        case batteryCurrentIntegratedSeconds
    }

    init() {}

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        inputWattHours = try values.decodeIfPresent(Double.self, forKey: .inputWattHours) ?? 0
        batteryWattHours = try values.decodeIfPresent(Double.self, forKey: .batteryWattHours) ?? 0
        batteryMilliAmpHours = try values.decodeIfPresent(Double.self, forKey: .batteryMilliAmpHours) ?? 0
        let legacyCoverage = try values.decodeIfPresent(TimeInterval.self, forKey: .integratedSeconds) ?? 0
        inputIntegratedSeconds = try values.decodeIfPresent(
            TimeInterval.self,
            forKey: .inputIntegratedSeconds
        ) ?? legacyCoverage
        batteryIntegratedSeconds = try values.decodeIfPresent(
            TimeInterval.self,
            forKey: .batteryIntegratedSeconds
        ) ?? legacyCoverage
        batteryCurrentIntegratedSeconds = try values.decodeIfPresent(
            TimeInterval.self,
            forKey: .batteryCurrentIntegratedSeconds
        ) ?? legacyCoverage
        integratedSeconds = max(
            inputIntegratedSeconds,
            max(batteryIntegratedSeconds, batteryCurrentIntegratedSeconds)
        )
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(inputWattHours, forKey: .inputWattHours)
        try values.encode(batteryWattHours, forKey: .batteryWattHours)
        try values.encode(batteryMilliAmpHours, forKey: .batteryMilliAmpHours)
        try values.encode(integratedSeconds, forKey: .integratedSeconds)
        try values.encode(inputIntegratedSeconds, forKey: .inputIntegratedSeconds)
        try values.encode(batteryIntegratedSeconds, forKey: .batteryIntegratedSeconds)
        try values.encode(batteryCurrentIntegratedSeconds, forKey: .batteryCurrentIntegratedSeconds)
    }
}

/// Trapezoidal integration of the live power readings.
///
/// Samples arrive about once a second while the app is in the foreground and stop
/// entirely when it is backgrounded. Rather than extrapolate across those gaps,
/// any interval longer than `maximumInterval` is discarded — the totals then read
/// as "energy measured while watching", which is honest, and `integratedSeconds`
/// records how much of the wall clock that covered.
nonisolated final class EnergyAccumulator {
    private struct Sample {
        let date: Date
        let inputWatts: Double?
        let batteryWatts: Double?
        let batteryAmps: Double?
    }

    /// Longest gap that still counts as continuous measurement.
    private static let maximumInterval: TimeInterval = 10

    private(set) var totals = EnergyTotals()
    private var previous: Sample?

    func reset() {
        totals = EnergyTotals()
        previous = nil
    }

    func add(_ snapshot: PowerSnapshot) {
        let sample = Sample(date: snapshot.date,
                            inputWatts: snapshot.inputWatts,
                            batteryWatts: snapshot.batteryWatts.map { max($0, 0) },
                            batteryAmps: snapshot.batteryCurrent.map { max($0, 0) })
        defer { previous = sample }
        guard let previous else { return }

        let interval = sample.date.timeIntervalSince(previous.date)
        guard interval > 0, interval <= Self.maximumInterval else { return }

        let hours = interval / 3600
        if let previousInput = previous.inputWatts, let input = sample.inputWatts {
            totals.inputWattHours += (previousInput + input) / 2 * hours
            totals.inputIntegratedSeconds += interval
        }
        if let previousBattery = previous.batteryWatts, let battery = sample.batteryWatts {
            totals.batteryWattHours += (previousBattery + battery) / 2 * hours
            totals.batteryIntegratedSeconds += interval
        }
        if let previousCurrent = previous.batteryAmps, let current = sample.batteryAmps {
            totals.batteryMilliAmpHours += (previousCurrent + current) / 2 * hours * 1000
            totals.batteryCurrentIntegratedSeconds += interval
        }
        totals.integratedSeconds = max(
            totals.inputIntegratedSeconds,
            max(totals.batteryIntegratedSeconds, totals.batteryCurrentIntegratedSeconds)
        )
    }
}
