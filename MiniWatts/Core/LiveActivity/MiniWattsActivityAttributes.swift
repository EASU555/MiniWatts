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

/// What appears in either compact Dynamic Island slot. Both sides deliberately
/// use the same type so every icon/readout — including an empty slot — is
/// available on the left and the right.
nonisolated enum LiveActivityCompactItem: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case statusIcon
    case chargingPower
    case socTemperature
    case batteryTemperature
    case hottestTemperature

    var id: Self { self }

    var metric: LiveActivityMetric? {
        switch self {
        case .none, .statusIcon: nil
        case .chargingPower: .chargingPower
        case .socTemperature: .socTemperature
        case .batteryTemperature: .batteryTemperature
        case .hottestTemperature: .hottestTemperature
        }
    }

    init(metric: LiveActivityMetric) {
        switch metric {
        case .chargingPower: self = .chargingPower
        case .socTemperature: self = .socTemperature
        case .batteryTemperature: self = .batteryTemperature
        case .hottestTemperature: self = .hottestTemperature
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
        /// Optional so an activity persisted by an older personal build still
        /// decodes. A fresh value also makes every one-second sensor sample a
        /// distinct ActivityKit state even when its rounded reading is unchanged.
        let sampledAt: Date?
        /// Optional so an activity created by an earlier personal build still
        /// decodes; nil preserves the original status-symbol presentation.
        let leadingItem: LiveActivityCompactItem?
        /// Optional so activities created by build 43 and earlier keep decoding.
        /// Their old right-side metric is recovered from `selectedMetric`.
        let trailingItem: LiveActivityCompactItem?
        let selectedMetric: LiveActivityMetric
        let isWireless: Bool
    }

    let startedAt: Date
}
