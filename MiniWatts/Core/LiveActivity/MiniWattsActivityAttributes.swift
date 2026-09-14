import ActivityKit
import Foundation

/// The one reading MiniWatts gives the most space to in the compact Dynamic Island.
/// The expanded presentation still shows every available measurement.
nonisolated enum LiveActivityMetric: String, Codable, CaseIterable, Identifiable, Sendable {
    case chargingPower
    case socTemperature
    case batteryTemperature
    case hottestTemperature

    var id: Self { self }
}

/// The compact, Codable boundary between the sensor process and WidgetKit.
/// Keep this comfortably below ActivityKit's 4 KB limit.
nonisolated struct MiniWattsActivityAttributes: ActivityAttributes {
    nonisolated struct ContentState: Codable, Hashable, Sendable {
        let chargeWatts: Double?
        let powerIsBatterySide: Bool
        let batteryPercent: Int?
        let socTemperature: Double?
        let batteryTemperature: Double?
        let hottestTemperature: Double?
        let hottestSensorName: String?
        let selectedMetric: LiveActivityMetric
        let isWireless: Bool
    }

    let startedAt: Date
}
