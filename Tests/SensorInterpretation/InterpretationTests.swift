import Foundation

@main struct InterpretationTests {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }

    static func near(_ actual: Double?, _ expected: Double, _ message: String) {
        check(actual.map { abs($0 - expected) < 0.000001 } ?? false, message)
    }

    static func temperature(_ name: String, _ value: Double, _ index: Int) -> HIDSensors.Reading {
        HIDSensors.Reading(name: name, kind: .temperature, value: value, index: index)
    }

    static func power(_ input: Double?, cell: Double?, at second: TimeInterval = 0,
                      connected: Bool? = true) -> PowerSnapshot {
        var registry: [String: Any] = ["IsCharging": true]
        if let connected { registry["ExternalConnected"] = connected }
        if let cell {
            registry["Voltage"] = 4_000
            registry["InstantAmperage"] = Int((cell / 4 * 1_000).rounded())
        }
        var rails: [HIDSensors.Reading] = []
        if let input {
            rails.append(HIDSensors.Reading(name: "Charger VQ0u", kind: .voltage, value: 10, index: 0))
            rails.append(HIDSensors.Reading(name: "Charger IQ0u", kind: .current, value: input / 10, index: 1))
        }
        return PowerSnapshot(date: Date(timeIntervalSince1970: second), registry: registry,
                             adapterDetails: ["Watts": 45], sensors: rails)
    }

    static func main() throws {
        let values = [38.7, 38.7, 38.7, 45.9]
        var gauges = values.enumerated().map { temperature("gas gauge battery", $0.element, $0.offset) }
        gauges.append(temperature("PMU tcal", 51.8, 10))
        let battery = PowerSnapshot(sensors: gauges)
        near(battery.batteryTemperature, 38.7, "Battery representative must be a median")
        near(battery.temperaturesByZone.first { $0.zone == .battery }?.representative,
             38.7, "Heat-map pin and battery readout disagree")
        near(battery.hottestSensor?.value, 45.9, "Hot battery outlier was silently deleted")
        near(battery.hottestSensor(in: .battery)?.value, 45.9, "Raw zone maximum changed")
        check(battery.batteryTemperatureReadings.count == 4 && battery.sensors.count == gauges.count,
              "Duplicate or calibration evidence was discarded")
        near(ChargeReading(battery).batteryTemperature, 38.7, "Compact readings did not use the representative")
        let medianFixtures: [[Double]] = [[32.1], [34, 36], [33, 35, 60]]
        for fixture in medianFixtures {
            let readings = fixture.enumerated().map { temperature("gas gauge battery", $0.element, $0.offset) }
            let snapshot = PowerSnapshot(sensors: readings)
            let expected: Double = fixture.count == 1 ? 32.1 : 35
            near(snapshot.batteryTemperature, expected, "Single/even/odd median changed")
        }
        let registryBattery = PowerSnapshot(registry: ["Temperature": 4_200], sensors: gauges)
        near(registryBattery.batteryTemperature, 42, "Registry temperature precedence changed")
        near(registryBattery.temperaturesByZone.first { $0.zone == .battery }?.representative,
             42, "Registry readout and battery pin disagree")
        check(PowerSnapshot().batteryTemperature == nil, "No battery sensor became a zero")
        print("PASS: representative medians, raw maximum, duplicate IDs and registry consistency")

        let sensors: [HIDSensors.Reading] = [
            temperature("Charger TQ2d", 99, 0), temperature("Charger TQ2j", 29, 1),
            temperature("Charger TQ0d", 96, 2), temperature("Charger TQ0j", 29, 3),
            temperature("Charger TQ0j", 61, 4), temperature("PMU tdev1", -12, 5),
            temperature("AMC ODTS", 0, 6), temperature("gas gauge battery", 39, 7),
            temperature("PMU tdie1", -12, 8), temperature("Camera die", .nan, 9)
        ]
        let warm = PowerSnapshot(registry: ["ExternalConnected": true], sensors: sensors)
        let excluded = Dictionary(uniqueKeysWithValues: warm.temperatureExclusions.map { ($0.reading.index, $0.reason) })
        check(excluded[0] == .unsupportedHotChargeDie, "Wrong-rail junction corroborated a hot die")
        check(excluded[5] == .coldDie && excluded[6] == .zero && excluded[9] == .outsideRange,
              "Temperature exclusion or indexed reason changed")
        check(excluded[2] == nil && excluded[8] == nil,
              "A backed hot die or a non-tdev negative reading was discarded")
        near(warm.hottestSensor?.value, 96, "A corroborated high temperature must remain visible")
        check(warm.sensors.count == sensors.count && warm.sensors[0].value == 99,
              "Interpretation edited raw evidence")
        let unknownConnection = PowerSnapshot(sensors: sensors)
        check(!unknownConnection.temperatureExclusions.contains { $0.reading.index == 2 },
              "An unknown connection was mistaken for a confirmed unplug")
        let unplugged = PowerSnapshot(registry: ["ExternalConnected": false], sensors: sensors)
        check(unplugged.temperatureExclusions.contains { $0.reading.index == 2 },
              "Unplugged high charge die bypassed the provisional check")
        print("PASS: provisional exclusions preserve raw evidence and same-rail corroboration")

        let partial = power(21.8, cell: 39.6)
        check(partial.inputWatts == nil, "Partial input escaped as complete input")
        near(partial.partialInputWatts, 21.8, "Partial evidence was discarded or doubled")
        check(partial.inputToCellPercent == nil && partial.notToCellWatts == nil
              && partial.adapterUtilisation == nil, "Partial input fed a derived ratio")
        let compact = ChargeReading(partial)
        near(compact.watts, 39.6, "Partial input did not fall back to the battery")
        check(compact.source == .intoBattery, "Battery fallback was labelled as port power")
        near(power(14, cell: 10).inputWatts, 14, "Normal low-power input changed")
        near(power(20, cell: 24).inputWatts, 20, "Exact 20% margin was rejected")
        near(power(5, cell: 6.5).inputWatts, 5, "Exact 1.5 W margin was rejected")
        check(power(5, cell: 6.6).inputWatts == nil, "Contradiction beyond both margins was trusted")
        near(power(-20, cell: 14).inputWatts, 20, "Personal input-sign convention changed")
        near(power(0, cell: 0).inputWatts, 0, "A genuine zero was lost")
        check(power(nil, cell: 10).partialInputWatts == nil, "Absent input invented partial evidence")
        let unknownPower = ChargeReading(power(21.8, cell: 39.6, connected: nil))
        check(unknownPower.watts == nil && unknownPower.externalConnectionObservation == nil,
              "Unknown connection lost its unavailable semantics")
        let accumulator = EnergyAccumulator()
        accumulator.add(power(21.8, cell: 39.6, at: 0))
        accumulator.add(power(21.8, cell: 39.6, at: 1))
        check(accumulator.totals.measuredInputWattHours == nil
              && accumulator.totals.inputIntegratedSeconds == 0
              && accumulator.totals.pairedIntegratedSeconds == 0,
              "Partial input entered energy or paired integration")
        near(accumulator.totals.measuredBatteryWattHours, 39.6 / 3600,
             "Excluding partial input also lost measured battery energy")
        accumulator.add(power(14, cell: 10, at: 2))
        check(accumulator.totals.inputIntegratedSeconds == 0,
              "Input integration bridged an incomplete-reading gap")
        accumulator.add(power(14, cell: 10, at: 3))
        check(accumulator.totals.inputIntegratedSeconds == 1, "Valid input did not recover")
        print("PASS: incomplete input, margins, compact source and per-channel integration gaps")

        let menu: [[String: Int]] = [
            ["Index": 1, "MaxVoltage": 9_000, "MaxCurrent": 3_000],
            ["Index": 2, "MaxVoltage": 65_535, "MaxCurrent": 65_535],
            ["Index": 3, "MaxVoltage": 0, "MaxCurrent": 3_000],
            ["Index": 4, "MaxVoltage": 5_000, "MaxCurrent": -1],
            ["Index": 5, "MaxVoltage": 5_000, "MaxCurrent": 3_000]
        ]
        let profiles = PowerSnapshot(adapterDetails: ["UsbHvcMenu": menu, "UsbHvcHvcIndex": 2])
        check(profiles.adapterProfiles.map(\.index) == [5, 1], "Invalid profile survived or valid order changed")
        check(profiles.negotiatedProfile == nil, "An invalid selected profile returned through fallback")
        let sentinel = PowerSnapshot(adapterDetails: ["Voltage": 65_535, "Current": 65_535])
        check(sentinel.negotiatedProfile == nil && sentinel.adapterCeilingWatts == nil
              && sentinel.adapterRatedWatts == nil, "Invalid dimensions became a 4,295 W rating")
        let valid = PowerSnapshot(adapterDetails: ["Voltage": 9_000, "Current": 3_000])
        near(valid.adapterRatedWatts, 27, "A valid negotiated fallback disappeared")
        print("PASS: invalid PD profiles and fallback rating are rejected without raw mutation")
    }
}
