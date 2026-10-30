import ActivityKit
import Foundation

/// The one reading MiniWatts gives the most space to in the compact Dynamic Island.
/// The expanded presentation still shows every available measurement.
nonisolated enum LiveActivityMetric: String, Codable, CaseIterable, Identifiable, Sendable {
    case chargingPower
    case socTemperature
    case batteryTemperature
    case hottestTemperature
    case cpuUsage
    case downloadSpeed
    case uploadSpeed
    case batteryChargingPower
    case chargeGainPercent
    case thermalPressure
    case chargerTemperature
    case wirelessCoilTemperature

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .chargingPower: "Charging power"
        case .socTemperature: "SoC temperature"
        case .batteryTemperature: "Battery temperature"
        case .hottestTemperature: "Hottest component"
        case .cpuUsage: "CPU usage"
        case .downloadSpeed: "Download speed"
        case .uploadSpeed: "Upload speed"
        case .batteryChargingPower: "Power into battery"
        case .chargeGainPercent: "Charge gained (%)"
        case .thermalPressure: "System thermal pressure"
        case .chargerTemperature: "Charge IC temperature"
        case .wirelessCoilTemperature: "Wireless coil temperature"
        }
    }

    var isTemperature: Bool {
        switch self {
        case .socTemperature, .batteryTemperature, .hottestTemperature,
             .chargerTemperature, .wirelessCoilTemperature: true
        default: false
        }
    }
}

/// The minimal island is used when other activities compete for space. Keep its
/// choice separate from the compact right side, with the old choice as default.
nonisolated enum LiveActivityMinimalSelection: String, CaseIterable, Identifiable, Sendable {
    case followRightSide
    case chargingPower
    case socTemperature
    case batteryTemperature
    case hottestTemperature
    case cpuUsage
    case downloadSpeed
    case uploadSpeed
    case batteryChargingPower
    case chargeGainPercent
    case thermalPressure
    case chargerTemperature
    case wirelessCoilTemperature

    var id: Self { self }

    func resolvedMetric(primary: LiveActivityMetric) -> LiveActivityMetric {
        switch self {
        case .followRightSide: primary
        case .chargingPower: .chargingPower
        case .socTemperature: .socTemperature
        case .batteryTemperature: .batteryTemperature
        case .hottestTemperature: .hottestTemperature
        case .cpuUsage: .cpuUsage
        case .downloadSpeed: .downloadSpeed
        case .uploadSpeed: .uploadSpeed
        case .batteryChargingPower: .batteryChargingPower
        case .chargeGainPercent: .chargeGainPercent
        case .thermalPressure: .thermalPressure
        case .chargerTemperature: .chargerTemperature
        case .wirelessCoilTemperature: .wirelessCoilTemperature
        }
    }

    var title: LocalizedStringResource {
        self == .followRightSide ? "Follow right side" : resolvedMetric(primary: .chargingPower).title
    }
}

/// What appears in the compact Dynamic Island's leading slot. Keeping the
/// status symbol as an explicit choice lets the user build either the familiar
/// icon + reading layout or a denser reading + reading layout.
nonisolated enum LiveActivityLeadingItem: String, Codable, CaseIterable, Identifiable, Sendable {
    case statusIcon
    case socIcon
    case batteryTemperatureIcon
    case hottestTemperatureIcon
    case cpuIcon
    case downloadIcon
    case uploadIcon
    case chargingPower
    case socTemperature
    case batteryTemperature
    case hottestTemperature
    case cpuUsage
    case downloadSpeed
    case uploadSpeed
    case batteryChargingPower
    case chargeGainPercent
    case thermalPressure
    case chargerTemperature
    case wirelessCoilTemperature

    var id: Self { self }

    var metric: LiveActivityMetric? {
        switch self {
        case .statusIcon, .socIcon, .batteryTemperatureIcon, .hottestTemperatureIcon,
             .cpuIcon, .downloadIcon, .uploadIcon: nil
        case .chargingPower: .chargingPower
        case .socTemperature: .socTemperature
        case .batteryTemperature: .batteryTemperature
        case .hottestTemperature: .hottestTemperature
        case .cpuUsage: .cpuUsage
        case .downloadSpeed: .downloadSpeed
        case .uploadSpeed: .uploadSpeed
        case .batteryChargingPower: .batteryChargingPower
        case .chargeGainPercent: .chargeGainPercent
        case .thermalPressure: .thermalPressure
        case .chargerTemperature: .chargerTemperature
        case .wirelessCoilTemperature: .wirelessCoilTemperature
        }
    }

    var iconMetric: LiveActivityMetric? {
        switch self {
        case .socIcon: .socTemperature
        case .batteryTemperatureIcon: .batteryTemperature
        case .hottestTemperatureIcon: .hottestTemperature
        case .cpuIcon: .cpuUsage
        case .downloadIcon: .downloadSpeed
        case .uploadIcon: .uploadSpeed
        case .statusIcon, .chargingPower, .socTemperature,
             .batteryTemperature, .hottestTemperature, .cpuUsage,
             .downloadSpeed, .uploadSpeed, .batteryChargingPower, .chargeGainPercent,
             .thermalPressure, .chargerTemperature, .wirelessCoilTemperature: nil
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .statusIcon: "Status icon"
        case .socIcon: "SoC icon"
        case .batteryTemperatureIcon: "Battery temperature icon"
        case .hottestTemperatureIcon: "Hottest temperature icon"
        case .cpuIcon: "CPU icon"
        case .downloadIcon: "Download icon"
        case .uploadIcon: "Upload icon"
        default: metric?.title ?? "Status icon"
        }
    }
}

/// System pressure, not a thermometer or a measured CPU clock/throttling flag.
nonisolated enum IslandThermalPressure: Int, Codable, Hashable, Sendable {
    case nominal, fair, serious, critical

    var title: LocalizedStringResource {
        switch self {
        case .nominal: "Nominal"
        case .fair: "Fair"
        case .serious: "Serious"
        case .critical: "Critical"
        }
    }
}

/// Three visual bands for the island. System thermal pressure is not a
/// temperature threshold; numeric power/rate bands only describe magnitude.
nonisolated enum IslandColorLevel: Equatable, Sendable {
    case green, yellow, red, unavailable

    static func thermal(_ pressure: IslandThermalPressure?) -> Self {
        switch pressure {
        case .nominal, .fair: .green
        case .serious: .yellow
        case .critical: .red
        case nil: .unavailable
        }
    }

    /// Nil means this metric retains its existing appearance. Missing or invalid
    /// values never get a healthy-looking color.
    static func classify(metric: LiveActivityMetric, value: Double?,
                         thermalPressure: IslandThermalPressure?) -> Self? {
        if metric == .thermalPressure { return thermal(thermalPressure) }
        if metric.isTemperature {
            guard let value, value.isFinite else { return .unavailable }
            return thermal(thermalPressure)
        }
        switch metric {
        case .chargingPower, .batteryChargingPower:
            guard let value, value.isFinite, value >= 0 else { return .unavailable }
            return value < 15 ? .green : value < 30 ? .yellow : .red
        case .downloadSpeed, .uploadSpeed:
            guard let value, value.isFinite, value >= 0 else { return .unavailable }
            return value < 1_000_000 ? .green : value < 10_000_000 ? .yellow : .red
        default:
            return nil
        }
    }
}

/// Optional additions keep previously persisted ActivityKit payloads decodable.
/// Slopes are Celsius per minute over continuous, source-stable observations.
/// No history arrays, raw dictionaries or inferred adapter watts cross this boundary.
nonisolated struct LiveActivityTelemetry: Codable, Hashable, Sendable {
    var sampledAt: Date?
    var batteryChargingWatts: Double?
    var partialInputWatts: Double?
    var chargerTemperature: Double?
    var wirelessCoilTemperature: Double?
    var thermalPressure: IslandThermalPressure?
    var chargeGainPercent: Int?
    var chargeStartPercent: Int?
    var chargeStartedAt: Date?
    var temperatureRates: [String: Double]?
    var showsTemperatureTrend: Bool?

    func trendRate(for metric: LiveActivityMetric) -> Double? {
        guard showsTemperatureTrend == true, metric.isTemperature,
              let rate = temperatureRates?[metric.rawValue], rate.isFinite else { return nil }
        return rate
    }

    func trendSymbol(for metric: LiveActivityMetric) -> String {
        guard let rate = trendRate(for: metric) else { return "" }
        return rate > 0.15 ? "↑" : rate < -0.15 ? "↓" : "→"
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
        /// presentation until the first new update arrives. New updates also
        /// use nil when the external-power connection could not be observed;
        /// chargeWatts is then nil, not an inferred discharge reading.
        let externalConnected: Bool?
        let batteryPercent: Int?
        /// Optional so an activity persisted by an older build still decodes.
        let cpuUsagePercent: Double?
        /// Optional so activities created by previous builds still decode.
        let downloadBytesPerSecond: Double?
        let uploadBytesPerSecond: Double?
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
        let leadingItem: LiveActivityLeadingItem?
        let selectedMetric: LiveActivityMetric
        /// Optional so activities persisted by older builds still decode. With no
        /// saved choice, their minimal view follows the compact right-side metric.
        let minimalMetric: LiveActivityMetric?
        let isWireless: Bool
        var telemetry: LiveActivityTelemetry? = nil
    }

    let startedAt: Date
}
