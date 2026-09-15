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

/// What appears in the compact Dynamic Island's leading slot. Keeping the
/// status symbol as an explicit choice lets the user build either the familiar
/// icon + reading layout or a denser reading + reading layout.
nonisolated enum LiveActivityLeadingItem: String, Codable, CaseIterable, Identifiable, Sendable {
    case statusIcon
    case chargingPower
    case socTemperature
    case batteryTemperature
    case hottestTemperature

    var id: Self { self }

    var metric: LiveActivityMetric? {
        switch self {
        case .statusIcon: nil
        case .chargingPower: .chargingPower
        case .socTemperature: .socTemperature
        case .batteryTemperature: .batteryTemperature
        case .hottestTemperature: .hottestTemperature
        }
    }
}

/// The compact, Codable boundary between the sensor process and WidgetKit.
/// Keep this comfortably below ActivityKit's 4 KB limit.
nonisolated struct MiniWattsActivityAttributes: ActivityAttributes {
    nonisolated struct ContentState: Codable, Hashable, Sendable {
        let chargeWatts: Double?
        let powerIsBatterySide: Bool
        /// Optional for compatibility with an activity created by build 11, whose
        /// persisted content state predates this field. Nil means the old charging
        /// presentation until the first new update arrives.
        let externalConnected: Bool?
        let batteryPercent: Int?
        let socTemperature: Double?
        let batteryTemperature: Double?
        let hottestTemperature: Double?
        let hottestSensorName: String?
        /// Optional so an activity created by an earlier personal build still
        /// decodes; nil preserves the original status-symbol presentation.
        let leadingItem: LiveActivityLeadingItem?
        let selectedMetric: LiveActivityMetric
        let isWireless: Bool
    }

    let startedAt: Date
}
