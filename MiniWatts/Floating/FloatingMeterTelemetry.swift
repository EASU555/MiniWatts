import Foundation
import SwiftUI

nonisolated enum FloatingMeterLayout: String, CaseIterable, Identifiable {
    case together
    case separatePages

    var id: Self { self }
}

nonisolated enum FloatingTemperatureSelection: String, CaseIterable, Identifiable {
    case all
    case soc
    case battery
    case charger
    case hottest

    var id: Self { self }
}

nonisolated enum FloatingSystemThermalState: Int, Hashable {
    case nominal
    case fair
    case serious
    case critical

    init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .nominal
        }
    }
}

nonisolated struct FloatingMeterData: Hashable {
    let date: Date
    let externalConnected: Bool
    let isWireless: Bool
    let watts: Double?
    let powerIsBatterySide: Bool
    let batteryPercent: Int?
    let socTemperature: Double?
    let batteryTemperature: Double?
    let chargerTemperature: Double?
    let hottestTemperature: Double?
    let hottestSensorName: String?
    let systemThermalState: FloatingSystemThermalState

    init(snapshot: PowerSnapshot, thermalState: ProcessInfo.ThermalState) {
        let reading = ChargeReading(snapshot)
        date = snapshot.date
        externalConnected = snapshot.externalConnected
        isWireless = reading.isWireless
        watts = reading.watts
        powerIsBatterySide = reading.source == .intoBattery || reading.source == .fromBattery
        batteryPercent = snapshot.percent
        socTemperature = snapshot.socTemperature
        batteryTemperature = snapshot.batteryTemperature
        chargerTemperature = snapshot.chargerTemperature
        hottestTemperature = snapshot.hottestSensor?.value
        hottestSensorName = snapshot.hottestSensor?.name
        systemThermalState = FloatingSystemThermalState(thermalState)
    }
}

/// SwiftUI copy of the video frame used in Settings. The real sample-buffer layer
/// remains mounted behind `RootView`, so changing a preference cannot move or tear
/// down the active Picture in Picture source.
struct FloatingMeterPreview: View {
    let controller: FloatingMeterController

    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width / 640, geometry.size.height / 360)
            FloatingMeterTelemetryFrame(
                data: controller.latestData,
                showPower: controller.showPower,
                showTemperatures: controller.showTemperatures,
                layout: controller.layout,
                temperatureSelection: controller.temperatureSelection
            )
            .frame(width: 640, height: 360)
            .scaleEffect(scale, anchor: .topLeading)
        }
        .background(.black)
        .environment(\.colorScheme, .dark)
    }
}

/// One 16:9 telemetry frame. Fixed dark colours are intentional: the system can
/// float this video over any app, so there is no reliable appearance behind it.
struct FloatingMeterTelemetryFrame: View {
    let data: FloatingMeterData?
    let showPower: Bool
    let showTemperatures: Bool
    let layout: FloatingMeterLayout
    let temperatureSelection: FloatingTemperatureSelection

    private var displaysPowerPage: Bool {
        guard showPower else { return false }
        guard showTemperatures, layout == .separatePages, let data else { return true }
        return Int(data.date.timeIntervalSinceReferenceDate / 4).isMultiple(of: 2)
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.035, green: 0.055, blue: 0.09), .black],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 16) {
                header
                if !showPower && !showTemperatures {
                    noSelection
                } else if layout == .separatePages && showPower && showTemperatures {
                    if displaysPowerPage { powerPage } else { temperaturePage }
                } else if showPower && showTemperatures {
                    togetherPage
                } else if showPower {
                    powerPage
                } else {
                    temperaturePage
                }
                footer
            }
            .padding(24)
        }
        .foregroundStyle(.white)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: data?.isWireless == true
                  ? "bolt.horizontal.circle.fill" : "bolt.circle.fill")
                .foregroundStyle(.cyan)
            Text(verbatim: "MINIWATTS")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .tracking(1.8)
            Spacer()
            if let percent = data?.batteryPercent {
                Label {
                    Text(verbatim: "\(percent)%")
                } icon: {
                    Image(systemName: "battery.75percent")
                }
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(.green)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(data == nil ? Color.secondary : Color.green)
                .frame(width: 8, height: 8)
            if data == nil {
                Text("WAITING")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
            } else {
                Text("LIVE · 1S")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            systemThermalStatus
            Spacer()
            if let date = data?.date {
                Text(date, format: .dateTime.hour().minute().second())
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var systemThermalStatus: some View {
        HStack(spacing: 5) {
            Image(systemName: systemThermalSymbol)
            Text("System thermal state")
            Text(systemThermalTitle)
        }
        .font(.system(size: 13, weight: .semibold, design: .rounded))
        .foregroundStyle(systemThermalColor)
        .lineLimit(1)
    }

    private var noSelection: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.slash")
                .font(.system(size: 40, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Select content in Settings")
                .font(.system(size: 24, weight: .semibold, design: .rounded))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var togetherPage: some View {
        HStack(spacing: 16) {
            powerReadout(compact: true)
                .frame(maxWidth: 220)
            temperatureContent(compact: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var powerPage: some View {
        powerReadout(compact: false)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func powerReadout(compact: Bool) -> some View {
        VStack(alignment: compact ? .leading : .center, spacing: 8) {
            Label("Charging power", systemImage: "bolt.fill")
                .font(.system(size: compact ? 17 : 21, weight: .semibold, design: .rounded))
                .foregroundStyle(.cyan)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: formatted(data?.watts))
                    .font(.system(size: compact ? 62 : 94, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.7)
                Text(verbatim: "W")
                    .font(.system(size: compact ? 22 : 30, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            Text(powerSourceText)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var temperaturePage: some View {
        VStack(spacing: 12) {
            Label("Component temperatures", systemImage: "thermometer.medium")
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .foregroundStyle(.orange)
            temperatureContent(compact: false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func temperatureContent(compact: Bool) -> some View {
        switch temperatureSelection {
        case .all:
            temperatureGrid
        case .soc:
            temperatureFocus("SoC", value: data?.socTemperature,
                             symbol: "cpu", compact: compact)
        case .battery:
            temperatureFocus("Battery", value: data?.batteryTemperature,
                             symbol: "battery.75percent", compact: compact)
        case .charger:
            temperatureFocus("Charger", value: data?.chargerTemperature,
                             symbol: "powerplug.fill", compact: compact)
        case .hottest:
            temperatureFocus("Hottest", value: data?.hottestTemperature,
                             symbol: "thermometer.high", detail: data?.hottestSensorName,
                             compact: compact)
        }
    }

    private var temperatureGrid: some View {
        HStack(spacing: 8) {
            temperatureCell("SoC", value: data?.socTemperature, symbol: "cpu")
            temperatureCell("Battery", value: data?.batteryTemperature,
                            symbol: "battery.75percent")
            temperatureCell("Charger", value: data?.chargerTemperature,
                            symbol: "powerplug.fill")
            temperatureCell("Hottest", value: data?.hottestTemperature,
                            symbol: "thermometer.high", detail: data?.hottestSensorName)
        }
    }

    private func temperatureCell(_ title: LocalizedStringKey,
                                 value: Double?,
                                 symbol: String,
                                 detail: String? = nil) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(temperatureColor(value))
            Text(title)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            // A single concatenated Text keeps the decimal and degree sign on one
            // typographic baseline and prevents narrow cells wrapping after '.'.
            (Text(verbatim: formatted(value))
                .font(.system(size: 29, weight: .bold, design: .rounded))
             + Text(verbatim: "°")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundColor(.secondary))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .allowsTightening(true)
                .frame(maxWidth: .infinity)
            Text(verbatim: detail ?? " ")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        }
    }

    private func temperatureFocus(_ title: LocalizedStringKey,
                                  value: Double?,
                                  symbol: String,
                                  detail: String? = nil,
                                  compact: Bool) -> some View {
        VStack(spacing: compact ? 8 : 10) {
            Label(title, systemImage: symbol)
                .font(.system(size: compact ? 17 : 20, weight: .semibold, design: .rounded))
                .foregroundStyle(temperatureColor(value))
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(verbatim: formatted(value))
                    .font(.system(size: compact ? 62 : 88, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.7)
                Text(verbatim: "°C")
                    .font(.system(size: compact ? 19 : 26, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            if let detail {
                Text(verbatim: detail)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 12)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
    }

    private var powerSourceText: LocalizedStringKey {
        guard data?.externalConnected == true else { return "Not charging" }
        if data?.powerIsBatterySide == true { return "Into battery" }
        return data?.isWireless == true ? "From wireless charger" : "From charger"
    }

    private func formatted(_ value: Double?) -> String {
        value?.formatted(.number.precision(.fractionLength(1))) ?? "—"
    }

    private func temperatureColor(_ value: Double?) -> Color {
        value.map(Color.mwTemperature) ?? .secondary
    }

    private var systemThermalTitle: LocalizedStringKey {
        switch data?.systemThermalState {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        case nil: return "—"
        }
    }

    private var systemThermalSymbol: String {
        switch data?.systemThermalState {
        case .nominal: return "checkmark.circle.fill"
        case .fair: return "thermometer.medium"
        case .serious: return "thermometer.high"
        case .critical: return "exclamationmark.triangle.fill"
        case nil: return "thermometer.medium"
        }
    }

    private var systemThermalColor: Color {
        switch data?.systemThermalState {
        case .nominal: return .green
        case .fair: return .yellow
        case .serious: return .orange
        case .critical: return .red
        case nil: return .secondary
        }
    }
}
