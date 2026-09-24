import Foundation

/// Energy totals for one stretch of charging, integrated from the live sensors.
///
/// The sandbox never hands out the pack's design capacity, but it does hand out
/// voltage and current at ~1 Hz on both sides of the charge IC. Integrating those
/// gives the two numbers that actually matter — how much energy the adapter
/// delivered, and how much of it reached the cell.
nonisolated struct EnergyTotals: Codable, Hashable, Sendable {
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
    /// Energy integrated only over intervals where both input and cell power
    /// were valid at both ends. Independent channel totals above remain useful,
    /// but cannot be divided or subtracted when their observed windows differ.
    var pairedInputWattHours: Double = 0
    var pairedBatteryWattHours: Double = 0
    var pairedIntegratedSeconds: TimeInterval = 0

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

    /// Share of paired charger-side energy reaching the cell, 0…100. This is
    /// not round-trip efficiency: the phone can consume part of the input power.
    var inputToCellPercent: Double? {
        guard pairedIntegratedSeconds > 0,
              pairedInputWattHours > 0.001,
              pairedBatteryWattHours >= 0,
              pairedBatteryWattHours <= pairedInputWattHours else { return nil }
        return pairedBatteryWattHours / pairedInputWattHours * 100
    }

    /// Input energy not reaching the cell over the *same* observed intervals.
    /// It includes system consumption and conversion losses, not just heat.
    var measuredNotToCellWattHours: Double? {
        guard inputToCellPercent != nil else { return nil }
        return pairedInputWattHours - pairedBatteryWattHours
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
        case pairedInputWattHours
        case pairedBatteryWattHours
        case pairedIntegratedSeconds
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
        // Older history has no evidence that the channel windows overlap. Keep
        // its measured totals, but leave the paired ratio unavailable.
        pairedInputWattHours = try values.decodeIfPresent(Double.self, forKey: .pairedInputWattHours) ?? 0
        pairedBatteryWattHours = try values.decodeIfPresent(Double.self, forKey: .pairedBatteryWattHours) ?? 0
        pairedIntegratedSeconds = try values.decodeIfPresent(TimeInterval.self, forKey: .pairedIntegratedSeconds) ?? 0
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
        try values.encode(pairedInputWattHours, forKey: .pairedInputWattHours)
        try values.encode(pairedBatteryWattHours, forKey: .pairedBatteryWattHours)
        try values.encode(pairedIntegratedSeconds, forKey: .pairedIntegratedSeconds)
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
        if let previousInput = previous.inputWatts, let input = sample.inputWatts,
           let previousBattery = previous.batteryWatts, let battery = sample.batteryWatts,
           previousInput.isFinite, input.isFinite,
           previousBattery.isFinite, battery.isFinite,
           previousInput >= previousBattery, input >= battery,
           previousBattery >= 0, battery >= 0 {
            totals.pairedInputWattHours += (previousInput + input) / 2 * hours
            totals.pairedBatteryWattHours += (previousBattery + battery) / 2 * hours
            totals.pairedIntegratedSeconds += interval
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
