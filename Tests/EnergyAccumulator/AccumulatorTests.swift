import Foundation

// Only the four fields consumed by EnergyAccumulator are needed in this
// command-line regression test; the app uses its full PowerSnapshot type.
nonisolated struct PowerSnapshot {
    let date: Date
    let inputWatts: Double?
    let batteryWatts: Double?
    let batteryCurrent: Double?
}

@main struct AccumulatorTests {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        precondition(value(), message)
    }

    static func sample(_ second: TimeInterval, input: Double?, cell: Double?) -> PowerSnapshot {
        PowerSnapshot(date: Date(timeIntervalSince1970: second),
                      inputWatts: input, batteryWatts: cell, batteryCurrent: nil)
    }

    static func near(_ left: Double?, _ right: Double, _ message: String) {
        check(left.map { abs($0 - right) < 0.00001 } ?? false, message)
    }

    static func main() throws {
        let paired = EnergyAccumulator()
        paired.add(sample(0, input: 10, cell: 5))
        paired.add(sample(1, input: 10, cell: 5))
        paired.add(sample(2, input: nil, cell: 5))
        paired.add(sample(3, input: nil, cell: 5))
        paired.add(sample(4, input: 20, cell: nil))
        paired.add(sample(5, input: 20, cell: nil))
        near(paired.totals.inputToCellPercent, 50, "Unpaired energy changed the paired share")
        near(paired.totals.measuredNotToCellWattHours, 5.0 / 3600,
             "Difference must use only paired intervals")
        check(paired.totals.inputIntegratedSeconds == 2, "Input coverage wrong")
        check(paired.totals.batteryIntegratedSeconds == 3, "Cell coverage wrong")
        check(paired.totals.pairedIntegratedSeconds == 1, "Paired coverage wrong")

        let disjoint = EnergyAccumulator()
        disjoint.add(sample(0, input: 10, cell: nil))
        disjoint.add(sample(1, input: 10, cell: nil))
        disjoint.add(sample(2, input: nil, cell: 5))
        disjoint.add(sample(3, input: nil, cell: 5))
        check(disjoint.totals.inputIntegratedSeconds == disjoint.totals.batteryIntegratedSeconds,
              "Test setup must have equal independent coverage")
        check(disjoint.totals.inputToCellPercent == nil, "Disjoint rails invented a percentage")
        check(disjoint.totals.measuredNotToCellWattHours == nil, "Disjoint rails invented a difference")
        check(disjoint.totals.integratedSeconds == 2,
              "Overall coverage must count the union of disjoint measured intervals")
        let disjointRestored = try JSONDecoder().decode(
            EnergyTotals.self, from: JSONEncoder().encode(disjoint.totals))
        check(disjointRestored == disjoint.totals,
              "Persistence lost disjoint union coverage")

        let overlap = EnergyAccumulator()
        overlap.add(PowerSnapshot(date: Date(timeIntervalSince1970: 0),
                                  inputWatts: 10, batteryWatts: 5, batteryCurrent: 1))
        overlap.add(PowerSnapshot(date: Date(timeIntervalSince1970: 1),
                                  inputWatts: 10, batteryWatts: 5, batteryCurrent: 1))
        check(overlap.totals.integratedSeconds == 1,
              "Three simultaneous channels must count as one interval")
        overlap.breakContinuity()
        overlap.add(sample(2, input: 10, cell: 5))
        check(overlap.totals.integratedSeconds == 1,
              "A short known pause must not interpolate energy")
        overlap.add(sample(3, input: 10, cell: 5))
        check(overlap.totals.integratedSeconds == 2,
              "Sampling must integrate again after a fresh baseline")
        overlap.add(sample(14, input: 10, cell: 5))
        check(overlap.totals.integratedSeconds == 2,
              "Long unobserved gaps must remain excluded")
        overlap.add(sample(15, input: nil, cell: nil))
        overlap.add(sample(16, input: nil, cell: nil))
        check(overlap.totals.integratedSeconds == 2,
              "Missing channels cannot increase coverage")

        let legacy = try JSONDecoder().decode(EnergyTotals.self, from: Data(
            "{\"inputWattHours\":0.01,\"batteryWattHours\":0.005,\"integratedSeconds\":10}".utf8))
        check(legacy.measuredInputWattHours != nil, "Legacy input total lost")
        check(legacy.measuredBatteryWattHours != nil, "Legacy cell total lost")
        check(legacy.inputToCellPercent == nil, "Legacy record invented paired evidence")
        let restored = try JSONDecoder().decode(EnergyTotals.self, from: JSONEncoder().encode(paired.totals))
        near(restored.inputToCellPercent, 50, "Paired totals did not persist")

        let inconsistent = EnergyAccumulator()
        inconsistent.add(sample(0, input: 10, cell: 12))
        inconsistent.add(sample(1, input: 10, cell: 12))
        check(inconsistent.totals.inputToCellPercent == nil, "Inconsistent rails were capped to 100%")

        let recovered = EnergyAccumulator()
        recovered.add(sample(0, input: 10, cell: 5))
        recovered.add(sample(1, input: 10, cell: 5))
        recovered.add(sample(2, input: 10, cell: 12))
        recovered.add(sample(3, input: 10, cell: 5))
        recovered.add(sample(4, input: 10, cell: 5))
        near(recovered.totals.inputToCellPercent, 50,
             "One invalid interval poisoned later valid paired readings")
        check(recovered.totals.pairedIntegratedSeconds == 2,
              "Invalid intervals were included in paired coverage")

        print("PASS: paired intervals, coverage union, continuity breaks, legacy history, persistence and invalid rails")
    }
}
