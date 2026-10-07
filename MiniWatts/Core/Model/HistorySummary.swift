import Foundation

/// Only observed channels contribute to a history total. Nil means no session
/// measured that channel; a measured zero remains a real zero.
nonisolated struct HistorySummary {
    let measuredInputWattHours: Double?
    let measuredBatteryWattHours: Double?
    let inputToCellPercent: Double?

    init(sessions: [ChargeSession]) {
        measuredInputWattHours = Self.sum(sessions.compactMap { $0.totals.measuredInputWattHours })
        measuredBatteryWattHours = Self.sum(sessions.compactMap { $0.totals.measuredBatteryWattHours })

        // Weight by paired energy rather than giving tiny top-ups equal weight.
        // Legacy records without paired evidence do not invent an efficiency.
        let paired = sessions.map(\.totals).filter { $0.inputToCellPercent != nil }
        let input = paired.reduce(0) { $0 + $1.pairedInputWattHours }
        let battery = paired.reduce(0) { $0 + $1.pairedBatteryWattHours }
        inputToCellPercent = input > 0 ? battery / input * 100 : nil
    }

    private static func sum(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +)
    }
}
