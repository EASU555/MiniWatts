import Foundation

/// Derives island additions from the existing one-second probe and charge session.
/// This owns no timer, sensor client, energy estimator or background execution.
nonisolated struct IslandTelemetryTracker {
    private var windows: [LiveActivityMetric: TemperatureTrendWindow] = [:]

    mutating func breakContinuity() { windows.removeAll(keepingCapacity: true) }

    mutating func update(snapshot: PowerSnapshot, session: ChargeSession?,
                         thermalState: Int) -> LiveActivityTelemetry {
        let values: [(LiveActivityMetric, Double?, String?)] = [
            (.batteryTemperature, snapshot.batteryTemperature, batterySource(snapshot)),
            (.socTemperature, snapshot.socTemperature, snapshot.hottestSensor(in: .soc)?.id),
            (.hottestTemperature, snapshot.hottestSensor?.value, snapshot.hottestSensor?.id),
            (.chargerTemperature, snapshot.chargerTemperature, snapshot.hottestSensor(in: .charger)?.id),
            (.wirelessCoilTemperature, snapshot.temperature(in: .wirelessCoil),
             snapshot.hottestSensor(in: .wirelessCoil)?.id)
        ]
        var rates: [String: Double] = [:]
        for (metric, value, source) in values {
            if let rate = windows[metric, default: TemperatureTrendWindow()].add(
                date: snapshot.date, value: value, source: source
            ) {
                rates[metric.rawValue] = rate
            }
        }
        let connected = snapshot.externalConnectionObservation == true
        var result = LiveActivityTelemetry()
        result.sampledAt = snapshot.date
        if connected, let watts = snapshot.batteryWatts, watts.isFinite, watts >= 0 {
            result.batteryChargingWatts = watts
        }
        result.partialInputWatts = snapshot.partialInputWatts
        result.chargerTemperature = snapshot.chargerTemperature
        result.wirelessCoilTemperature = snapshot.temperature(in: .wirelessCoil)
        result.thermalPressure = IslandThermalPressure(rawValue: thermalState)
        result.chargeGainPercent = Self.chargeGain(start: session?.startPercent,
                                                  current: snapshot.percent,
                                                  connected: snapshot.externalConnectionObservation)
        if connected, let session {
            result.chargeStartPercent = session.startPercent
            result.chargeStartedAt = session.start
        }
        result.temperatureRates = rates
        return result
    }

    /// Percentage points from directly observed system levels; never Wh/capacity.
    /// Consumption during charging offsets the increase. Missing endpoints do not
    /// become zero. A pause keeps the session baseline; a confirmed unplug ends it.
    static func chargeGain(start: Int?, current: Int?, connected: Bool?) -> Int? {
        guard connected == true, let start, let current,
              (0...100).contains(start), (0...100).contains(current) else { return nil }
        return max(current - start, 0)
    }

    private func batterySource(_ snapshot: PowerSnapshot) -> String? {
        if snapshot.registryTemperature != nil { return "registry-temperature" }
        let sources = snapshot.batteryTemperatureReadings.map(\.id).sorted()
        return sources.isEmpty ? nil : "median:" + sources.joined(separator: "|")
    }
}
