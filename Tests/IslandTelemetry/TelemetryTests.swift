import Foundation

@main struct TelemetryTests {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }

    static func near(_ actual: Double?, _ expected: Double, _ message: String) {
        check(actual.map { abs($0 - expected) < 0.000001 } ?? false, message)
    }

    static func date(_ second: Double) -> Date { Date(timeIntervalSince1970: second) }

    static func snapshot(at second: Double = 0, percent: Int? = 61,
                         connected: Bool? = true, watts: Double? = 20,
                         battery: Double = 35, batteryIndex: Int = 0,
                         input: Double? = 30, registryTemperature: Int? = nil) -> PowerSnapshot {
        var registry: [String: Any] = [:]
        if let connected { registry["ExternalConnected"] = connected }
        if let registryTemperature { registry["Temperature"] = registryTemperature }
        if let watts {
            registry["Voltage"] = 4_000
            registry["InstantAmperage"] = Int(watts * 250)
        }
        var sensors = [
            HIDSensors.Reading(name: "gas gauge battery", kind: .temperature, value: battery, index: batteryIndex),
            HIDSensors.Reading(name: "PMU tdie1", kind: .temperature, value: 40, index: 10),
            HIDSensors.Reading(name: "Charger TQ0j", kind: .temperature, value: 42, index: 11),
            HIDSensors.Reading(name: "Wireless coil", kind: .temperature, value: 36, index: 12)
        ]
        if let input {
            sensors.append(HIDSensors.Reading(name: "Charger VQ0u", kind: .voltage, value: 10, index: 20))
            sensors.append(HIDSensors.Reading(name: "Charger IQ0u", kind: .current, value: input / 10, index: 21))
        }
        return PowerSnapshot(date: date(second), systemBatteryPercent: percent,
                             registry: registry, sensors: sensors)
    }

    static func main() throws {
        check(IslandColorLevel.thermal(.nominal) == .green && IslandColorLevel.thermal(.fair) == .green,
              "Normal and slightly elevated iOS states should be green")
        check(IslandColorLevel.thermal(.serious) == .yellow && IslandColorLevel.thermal(.critical) == .red,
              "Serious and critical iOS states need different colors")
        check(IslandColorLevel.classify(metric: .batteryTemperature, value: 50, thermalPressure: .nominal) == .green,
              "Temperature color must follow the system state, not an invented Celsius threshold")
        check(IslandColorLevel.classify(metric: .socTemperature, value: 30, thermalPressure: .critical) == .red,
              "Temperature color did not reflect critical system state")
        check(IslandColorLevel.classify(metric: .batteryTemperature, value: nil, thermalPressure: .nominal) == .unavailable &&
              IslandColorLevel.classify(metric: .batteryTemperature, value: 35, thermalPressure: nil) == .unavailable,
              "Missing temperature or system state appeared healthy")
        for metric in [LiveActivityMetric.chargingPower, .batteryChargingPower] {
            for (value, level) in [(0.0, IslandColorLevel.green), (14.999, .green), (15, .yellow),
                                   (29.999, .yellow), (30, .red)] {
                check(IslandColorLevel.classify(metric: metric, value: value, thermalPressure: nil) == level,
                      "Unexpected power color boundary")
            }
        }
        for metric in [LiveActivityMetric.downloadSpeed, .uploadSpeed] {
            for (value, level) in [(0.0, IslandColorLevel.green), (999_999, .green), (1_000_000, .yellow),
                                   (9_999_999, .yellow), (10_000_000, .red)] {
                check(IslandColorLevel.classify(metric: metric, value: value, thermalPressure: nil) == level,
                      "Unexpected network color boundary")
            }
            check(IslandColorLevel.classify(metric: metric, value: .nan, thermalPressure: nil) == .unavailable &&
                  IslandColorLevel.classify(metric: metric, value: -1, thermalPressure: nil) == .unavailable,
                  "Invalid traffic should not acquire a color")
        }
        check(IslandColorLevel.classify(metric: .cpuUsage, value: 80, thermalPressure: .critical) == nil,
              "Unrelated metrics must keep their existing appearance")
        print("PASS: island color bands, system thermal semantics, missing values and boundaries")

        var warming = TemperatureTrendWindow()
        for second in 0..<60 {
            check(warming.add(date: date(Double(second)), value: 30 + Double(second) / 100,
                              source: "sensor-A") == nil, "A trend appeared before one minute")
        }
        near(warming.add(date: date(60), value: 30.6, source: "sensor-A"), 0.6,
             "Linear warming was not Celsius per minute")
        near(warming.add(date: date(60), value: 90, source: "sensor-A"), 0.6,
             "A duplicate timestamp entered the trend twice")
        check(warming.add(date: date(61), value: 45, source: "sensor-B") == nil,
              "A sensor switch became a temperature spike")
        check(warming.add(date: date(67), value: 46, source: "sensor-B") == nil,
              "A sampling gap retained the old slope")
        check(warming.add(date: date(66), value: 47, source: "sensor-B") == nil,
              "Backwards time retained the old slope")
        check(warming.add(date: date(68), value: .nan, source: "sensor-B") == nil,
              "NaN entered the trend")
        check(warming.add(date: date(69), value: nil, source: "sensor-B") == nil,
              "A missing reading became zero")
        check(warming.add(date: date(70), value: 30, source: nil) == nil,
              "An unidentified source acquired a trend")
        var cooling = TemperatureTrendWindow()
        for second in 0...400 {
            cooling.add(date: date(Double(second)), value: 40 - Double(second) / 200,
                        source: "sensor-C")
        }
        near(cooling.rate, -0.3, "Bounded rolling history changed a steady cooling slope")
        cooling.reset()
        check(cooling.rate == nil, "Explicit suspension did not reset the trend")
        var steady = TemperatureTrendWindow()
        for second in 0...120 {
            steady.add(date: date(Double(second)), value: 35 + (second.isMultiple(of: 2) ? 0.05 : -0.05),
                       source: "sensor-D")
        }
        check(abs(steady.rate ?? 1) < 0.01, "Small alternating noise became a heating trend")
        print("PASS: trend warm-up, regression, bounds, jitter, source changes, gaps and invalid readings")

        check(IslandTelemetryTracker.chargeGain(start: 53, current: 61, connected: true) == 8,
              "53 to 61 was not eight percentage points")
        check(IslandTelemetryTracker.chargeGain(start: 61, current: 53, connected: true) == 0,
              "Consumption was displayed as extra charge")
        check(IslandTelemetryTracker.chargeGain(start: nil, current: 61, connected: true) == nil,
              "Missing starting level became zero")
        check(IslandTelemetryTracker.chargeGain(start: 53, current: nil, connected: true) == nil,
              "Missing current level retained an old gain")
        let unavailableConnections: [Bool?] = [false, nil]
        for connection in unavailableConnections {
            check(IslandTelemetryTracker.chargeGain(start: 53, current: 61, connected: connection) == nil,
                  "An unplugged or unknown session kept a live charge gain")
        }
        check(IslandTelemetryTracker.chargeGain(start: -1, current: 61, connected: true) == nil,
              "Invalid percentage was admitted")

        var session = ChargeSession(start: date(0), startPercent: 53, adapterName: nil,
                                    adapterRatedWatts: nil, isWireless: false)
        session.recordPercent(55) // Deliberately older than the current system level.
        var tracker = IslandTelemetryTracker()
        var summary = tracker.update(snapshot: snapshot(), session: session, thermalState: 0)
        check(summary.chargeGainPercent == 8 && summary.chargeStartPercent == 53,
              "Island gain used stale history instead of the current system API result")
        near(summary.batteryChargingWatts, 20, "Independent cell power was replaced by adapter input")
        near(summary.chargerTemperature, 42, "Charge IC sensor did not reach the payload")
        near(summary.wirelessCoilTemperature, 36, "Coil sensor did not reach the payload")
        check(summary.thermalPressure == .nominal, "Thermal pressure was inferred from temperature")
        tracker.breakContinuity()
        summary = tracker.update(snapshot: snapshot(at: 100, percent: 62), session: session, thermalState: 2)
        check(summary.chargeGainPercent == 9 && summary.temperatureRates?.isEmpty == true,
              "A pause erased the session baseline or preserved an expired trend")
        check(summary.thermalPressure == .serious, "System pressure was not carried independently")
        print("PASS: direct system percentage points, current endpoints, session continuity and thermal pressure")

        let partial = tracker.update(snapshot: snapshot(at: 101, input: 10), session: session, thermalState: 1)
        near(partial.partialInputWatts, 10, "Incomplete-input evidence was dropped or scaled")
        near(partial.batteryChargingWatts, 20, "Incomplete input erased independently measured cell power")
        let zero = tracker.update(snapshot: snapshot(at: 102, watts: 0), session: session, thermalState: 0)
        near(zero.batteryChargingWatts, 0, "Measured zero was confused with no reading")
        for frame in [snapshot(at: 103, connected: false), snapshot(at: 104, connected: nil),
                      snapshot(at: 105, watts: -4), snapshot(at: 106, watts: nil)] {
            let result = tracker.update(snapshot: frame, session: session, thermalState: 99)
            check(result.batteryChargingWatts == nil, "Unavailable cell charging power became positive watts")
            check(result.thermalPressure == nil, "Unknown system state became nominal")
        }
        tracker.breakContinuity()
        for second in 0...65 {
            summary = tracker.update(snapshot: snapshot(at: Double(second), battery: 35 + Double(second) / 100),
                                     session: session, thermalState: 0)
        }
        near(summary.temperatureRates?[LiveActivityMetric.batteryTemperature.rawValue], 0.6,
             "Battery-source trend was not computed from existing samples")
        summary = tracker.update(snapshot: snapshot(at: 66, batteryIndex: 2), session: session, thermalState: 0)
        check(summary.temperatureRates?[LiveActivityMetric.batteryTemperature.rawValue] == nil,
              "Changing the battery median's source set retained a slope")
        summary = tracker.update(snapshot: snapshot(at: 67, registryTemperature: 3_800), session: session, thermalState: 0)
        check(summary.temperatureRates?[LiveActivityMetric.batteryTemperature.rawValue] == nil,
              "Changing from HID median to registry temperature retained a slope")
        print("PASS: independent cell readings, incomplete input, measured zero and temperature provenance")

        summary.showsTemperatureTrend = true
        summary.temperatureRates = [LiveActivityMetric.batteryTemperature.rawValue: 0.6]
        check(summary.trendSymbol(for: .batteryTemperature) == "↑", "Warming arrow missing")
        summary.temperatureRates = [LiveActivityMetric.batteryTemperature.rawValue: -0.6]
        check(summary.trendSymbol(for: .batteryTemperature) == "↓", "Cooling arrow missing")
        summary.temperatureRates = [LiveActivityMetric.batteryTemperature.rawValue: 0.05]
        check(summary.trendSymbol(for: .batteryTemperature) == "→", "Noise escaped the stable deadband")
        summary.showsTemperatureTrend = false
        check(summary.trendSymbol(for: .batteryTemperature).isEmpty,
              "Disabling the trend did not remove its presentation")
        for metric in LiveActivityMetric.allCases {
            check(LiveActivityLeadingItem(rawValue: metric.rawValue)?.metric == metric,
                  "A selectable metric is missing from the left side")
            check(LiveActivityMinimalSelection(rawValue: metric.rawValue)?.resolvedMetric(primary: .chargingPower) == metric,
                  "A selectable metric is missing from the multi-activity island")
        }
        var payload = MiniWattsActivityAttributes.ContentState(
            chargeWatts: 30, powerIsBatterySide: false, externalConnected: true,
            batteryPercent: 61, cpuUsagePercent: 45, downloadBytesPerSecond: 1_234_567,
            uploadBytesPerSecond: 2_345_678, socTemperature: 40, batteryTemperature: 35,
            hottestTemperature: 42, hottestSensorName: String(repeating: "S", count: 512),
            sampledAt: date(67), leadingItem: .chargeGainPercent,
            selectedMetric: .batteryChargingPower, minimalMetric: .thermalPressure,
            isWireless: false, telemetry: summary)
        let data = try JSONEncoder().encode(payload)
        check(data.count < 3_000, "Content-state additions approach ActivityKit's 4 KB limit")
        let roundTrip = try JSONDecoder().decode(MiniWattsActivityAttributes.ContentState.self, from: data)
        check(roundTrip == payload,
              "The new payload did not round-trip")
        payload.telemetry = nil
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as! [String: Any]
        legacy.removeValue(forKey: "telemetry")
        let decoded = try JSONDecoder().decode(MiniWattsActivityAttributes.ContentState.self,
                                               from: JSONSerialization.data(withJSONObject: legacy))
        check(decoded.telemetry == nil, "Activities created before this build no longer decode")
        print("PASS: trend switch, all three metric menus, legacy payload decoding and payload size (\(data.count) bytes)")
    }
}
