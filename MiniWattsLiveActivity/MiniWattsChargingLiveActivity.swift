import ActivityKit
import Foundation
import SwiftUI
import WidgetKit

struct MiniWattsChargingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MiniWattsActivityAttributes.self) { context in
            ChargeLockScreenView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.92))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        Image(systemName: context.state.isWireless
                              ? "bolt.horizontal.circle.fill" : "bolt.circle.fill")
                            .foregroundStyle(.yellow)
                        if context.state.externalConnected == true {
                            Text("Charging")
                                .font(.caption.weight(.semibold))
                        } else if context.state.externalConnected == false {
                            Text("On battery")
                                .font(.caption.weight(.semibold))
                        } else {
                            Text("Power unavailable").font(.caption.weight(.semibold))
                        }
                    }
                }

                DynamicIslandExpandedRegion(.trailing) {
                    if let percent = context.state.batteryPercent {
                        Label {
                            Text(verbatim: "\(percent)%")
                        } icon: {
                            Image(systemName: "battery.75percent")
                        }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.green)
                    }
                }

                DynamicIslandExpandedRegion(.center) {
                    PrimaryMetricView(state: context.state, isStale: context.isStale, showsFootnote: false)
                        .padding(.top, 4)
                }

                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 4) {
                        ExpandedMetricStrip(state: context.state, isStale: context.isStale)
                        TelemetryDetails(state: context.state, isStale: context.isStale)
                    }
                        .padding(.top, 4)
                }
            } compactLeading: {
                CompactLeadingContent(state: context.state, isStale: context.isStale)
            } compactTrailing: {
                CompactMetricValue(state: context.state)
                    .foregroundStyle(context.isStale
                                     ? Color.secondary : color(for: context.state.selectedMetric, state: context.state))
                    .accessibilityLabel(label(for: context.state.selectedMetric))
                    .accessibilityValue(Text(verbatim: formattedValue(
                        for: context.state.selectedMetric,
                        state: context.state
                    )))
            } minimal: {
                let metric = context.state.minimalMetric ?? context.state.selectedMetric
                if context.isStale {
                    Image(systemName: "pause.fill")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Reading paused")
                } else if metric == .thermalPressure,
                          let pressure = context.state.telemetry?.thermalPressure {
                    ViewThatFits(in: .horizontal) {
                        Text(pressure.title).fixedSize()
                        Image(systemName: pressureSymbol(pressure))
                    }
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(pressureColor(pressure))
                    .accessibilityLabel("System thermal pressure")
                    .accessibilityValue(Text(pressure.title))
                } else if let values = minimalValueVariants(for: metric, state: context.state) {
                    ViewThatFits(in: .horizontal) {
                        Text(verbatim: values.preferredWithUnit)
                            .fixedSize(horizontal: true, vertical: false)
                        Text(verbatim: values.precise)
                            .fixedSize(horizontal: true, vertical: false)
                        Text(verbatim: values.roundedWithUnit)
                            .fixedSize(horizontal: true, vertical: false)
                        Text(verbatim: values.rounded)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                        .font(.caption2.monospacedDigit().weight(.heavy))
                        .foregroundStyle(color(for: metric, state: context.state))
                        .accessibilityLabel(label(for: metric))
                        .accessibilityValue(Text(verbatim: formattedValue(for: metric,
                                                                          state: context.state)))
                        .accessibilityAddTraits(.updatesFrequently)
                } else {
                    Text(verbatim: "—")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(label(for: metric))
                        .accessibilityValue(Text("No reading"))
                }
            }
            .keylineTint(context.isStale ? .secondary : color(for: context.state.minimalMetric ?? context.state.selectedMetric, state: context.state))
        }
    }
}

private struct ChargeLockScreenView: View {
    let context: ActivityViewContext<MiniWattsActivityAttributes>

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: context.state.isWireless
                          ? "bolt.horizontal.circle.fill" : "bolt.circle.fill")
                        .foregroundStyle(.yellow)
                    Text("MiniWatts")
                        .font(.headline)
                }
                Spacer()
                if context.isStale {
                    Label("Reading paused", systemImage: "pause.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let percent = context.state.batteryPercent {
                    Label {
                        Text(verbatim: "\(percent)%")
                    } icon: {
                        Image(systemName: "battery.75percent")
                    }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.green)
                }
            }

            HStack(alignment: .center, spacing: 16) {
                PrimaryMetricView(state: context.state, isStale: context.isStale)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ExpandedMetricStrip(state: context.state, isStale: context.isStale)
                    .frame(maxWidth: .infinity)
            }
            TelemetryDetails(state: context.state, isStale: context.isStale)
        }
        .padding()
        .foregroundStyle(.white)
        .accessibilityElement(children: .combine)
    }
}

private struct PrimaryMetricView: View {
    let state: MiniWattsActivityAttributes.ContentState
    let isStale: Bool
    var showsFootnote = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label(for: state.selectedMetric))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if state.selectedMetric == .thermalPressure {
                    if let pressure = state.telemetry?.thermalPressure {
                        Text(pressure.title).font(.title2.weight(.bold))
                    } else { Text(verbatim: "—").font(.title2.weight(.bold)) }
                } else {
                    Text(verbatim: primaryNumber(for: state.selectedMetric, state: state))
                        .font(.title2.monospacedDigit().weight(.bold))
                    Text(verbatim: networkRate(for: state.selectedMetric, state: state)?.unit
                        ?? unit(for: state.selectedMetric))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(isStale ? Color.secondary : color(for: state.selectedMetric, state: state))

            if showsFootnote && state.selectedMetric == .chargingPower {
                if state.chargeWatts == nil {
                    Text("Power unavailable").font(.caption2).foregroundStyle(.secondary)
                } else if state.externalConnected == false {
                    Text("Battery draw")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if state.powerIsBatterySide {
                    Text("Into battery")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("From charger")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else if showsFootnote && state.selectedMetric == .batteryChargingPower {
                Text("Cell-side power, not adapter input")
                    .font(.caption2).foregroundStyle(.secondary)
            } else if showsFootnote && state.selectedMetric == .chargeGainPercent,
                      let start = state.telemetry?.chargeStartPercent, let current = state.batteryPercent {
                Text(verbatim: "\(start)% → \(current)%")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            } else if showsFootnote && state.selectedMetric == .hottestTemperature,
                      let name = state.hottestSensorName {
                Text(name)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if showsFootnote && state.selectedMetric == .cpuUsage {
                Text("Whole-device average")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if showsFootnote && (state.selectedMetric == .downloadSpeed
                        || state.selectedMetric == .uploadSpeed) {
                Text("Whole-device traffic")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label(for: state.selectedMetric))
        .accessibilityValue(Text(verbatim: formattedValue(for: state.selectedMetric, state: state)))
        .accessibilityAddTraits(.updatesFrequently)
    }
}

/// Two small rows of provenance and context, not another grid of live counters.
/// The sample timestamp is app receipt time; it is not proof of sensor accuracy.
private struct TelemetryDetails: View {
    let state: MiniWattsActivityAttributes.ContentState
    let isStale: Bool

    private var trendMetric: LiveActivityMetric? {
        if state.selectedMetric.isTemperature { return state.selectedMetric }
        if let left = state.leadingItem?.metric, left.isTemperature { return left }
        if let minimal = state.minimalMetric, minimal.isTemperature { return minimal }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                if isStale {
                    Label("Reading paused", systemImage: "pause.circle")
                } else if state.telemetry?.partialInputWatts != nil {
                    Label("Input reading incomplete", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                } else if state.chargeWatts == nil {
                    Label("Power unavailable", systemImage: "questionmark.circle")
                } else if state.externalConnected == false {
                    Label("Battery draw", systemImage: "battery.75percent")
                } else if state.powerIsBatterySide {
                    Label("Into battery", systemImage: "battery.75percent")
                } else {
                    Label("From charger", systemImage: "powerplug.fill")
                }
                Spacer(minLength: 4)
                if let date = state.sampledAt {
                    Text("Sample received")
                    Text(date, style: .time).monospacedDigit()
                }
            }
            HStack(spacing: 8) {
                if let gain = state.telemetry?.chargeGainPercent {
                    Label {
                        HStack(spacing: 2) {
                            Text("Charge gained")
                            Text(verbatim: "+\(gain)%")
                        }
                    } icon: { Image(systemName: "battery.badge.plus") }
                    .accessibilityLabel("Charge gained (%)")
                    .accessibilityValue(Text(verbatim: "+\(gain)%"))
                }
                Spacer(minLength: 0)
                if let metric = trendMetric, let telemetry = state.telemetry,
                   let rate = telemetry.trendRate(for: metric) {
                    Text(verbatim: telemetry.trendSymbol(for: metric)
                         + oneDecimal(abs(rate)) + "°C/min")
                        .accessibilityLabel(label(for: metric))
                        .accessibilityValue(Text(verbatim: oneDecimal(rate) + "°C/min"))
                } else if let metric = trendMetric, numericValue(for: metric, state: state) != nil,
                          state.telemetry?.showsTemperatureTrend == true {
                    Text("Collecting trend")
                }
                Spacer(minLength: 0)
                if let pressure = state.telemetry?.thermalPressure {
                    Label { Text(pressure.title) } icon: { Image(systemName: pressureSymbol(pressure)) }
                        .foregroundStyle(isStale ? Color.secondary : pressureColor(pressure))
                        .accessibilityLabel("System thermal pressure")
                        .accessibilityValue(Text(pressure.title))
                }
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
}

private struct ExpandedMetricStrip: View {
    let state: MiniWattsActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        HStack(spacing: 8) {
            SmallMetric(metric: .chargingPower, state: state, isStale: isStale)
            SmallMetric(metric: .socTemperature, state: state, isStale: isStale)
            SmallMetric(metric: .batteryTemperature, state: state, isStale: isStale)
            SmallMetric(metric: .hottestTemperature, state: state, isStale: isStale)
        }
    }
}

private struct SmallMetric: View {
    let metric: LiveActivityMetric
    let state: MiniWattsActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: symbol(for: metric))
                .font(.caption2)
                .foregroundStyle(isStale ? Color.secondary : color(for: metric, state: state))
            Text(shortLabel(for: metric))
                .font(.system(.caption2, design: .rounded, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(verbatim: shortValue(for: metric, state: state))
                .font(.system(.caption, design: .rounded, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(isStale ? Color.secondary : color(for: metric, state: state))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label(for: metric))
        .accessibilityValue(Text(verbatim: formattedValue(for: metric, state: state)))
    }
}

private struct CompactMetricValue: View {
    let state: MiniWattsActivityAttributes.ContentState

    var body: some View {
        Text(verbatim: shortValue(for: state.selectedMetric, state: state))
            .font(.caption.monospacedDigit().weight(.bold))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
    }
}

private struct CompactLeadingContent: View {
    let state: MiniWattsActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        if isStale {
            Image(systemName: "pause.fill")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Reading paused")
        } else if let metric = (state.leadingItem ?? .statusIcon).iconMetric {
            Image(systemName: symbol(for: metric))
                .foregroundStyle(color(for: metric, state: state))
                .accessibilityLabel(label(for: metric))
        } else if let metric = (state.leadingItem ?? .statusIcon).metric {
            Text(verbatim: shortValue(for: metric, state: state))
                .font(.caption2.monospacedDigit().weight(.bold))
                .foregroundStyle(color(for: metric, state: state))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .accessibilityLabel(label(for: metric))
                .accessibilityValue(Text(verbatim: formattedValue(for: metric, state: state)))
        } else {
            Image(systemName: state.isWireless
                  ? "bolt.horizontal.circle.fill" : "bolt.circle.fill")
                .foregroundStyle(.yellow)
                .accessibilityLabel(state.externalConnected == false
                                    ? "On battery" : "Charging")
        }
    }
}

private func numericValue(
    for metric: LiveActivityMetric,
    state: MiniWattsActivityAttributes.ContentState
) -> Double? {
    switch metric {
    case .chargingPower: state.chargeWatts
    case .socTemperature: state.socTemperature
    case .batteryTemperature: state.batteryTemperature
    case .hottestTemperature: state.hottestTemperature
    case .cpuUsage: state.cpuUsagePercent
    case .downloadSpeed: state.downloadBytesPerSecond
    case .uploadSpeed: state.uploadBytesPerSecond
    case .batteryChargingPower: state.telemetry?.batteryChargingWatts
    case .chargeGainPercent: state.telemetry?.chargeGainPercent.map(Double.init)
    case .thermalPressure: nil
    case .chargerTemperature: state.telemetry?.chargerTemperature
    case .wirelessCoilTemperature: state.telemetry?.wirelessCoilTemperature
    }
}

private func label(for metric: LiveActivityMetric) -> LocalizedStringKey {
    switch metric {
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

private func shortLabel(for metric: LiveActivityMetric) -> LocalizedStringKey {
    switch metric {
    case .chargingPower: "Power"
    case .socTemperature: "SoC"
    case .batteryTemperature: "Battery"
    case .hottestTemperature: "Hottest"
    case .cpuUsage: "CPU"
    case .downloadSpeed: "Download"
    case .uploadSpeed: "Upload"
    case .batteryChargingPower: "Into battery"
    case .chargeGainPercent: "Charge gained"
    case .thermalPressure: "Thermal"
    case .chargerTemperature: "Charge IC"
    case .wirelessCoilTemperature: "Coil"
    }
}

private func symbol(for metric: LiveActivityMetric) -> String {
    switch metric {
    case .chargingPower: "bolt.fill"
    case .socTemperature: "cpu"
    case .batteryTemperature: "battery.75percent"
    case .hottestTemperature: "thermometer.high"
    case .cpuUsage: "cpu"
    case .downloadSpeed: "arrow.down"
    case .uploadSpeed: "arrow.up"
    case .batteryChargingPower: "battery.75percent"
    case .chargeGainPercent: "battery.badge.plus"
    case .thermalPressure: "thermometer.medium"
    case .chargerTemperature: "powerplug.fill"
    case .wirelessCoilTemperature: "wave.3.right.circle"
    }
}

private func color(for metric: LiveActivityMetric,
                   state: MiniWattsActivityAttributes.ContentState) -> Color {
    if let level = IslandColorLevel.classify(metric: metric, value: numericValue(for: metric, state: state),
                                              thermalPressure: state.telemetry?.thermalPressure) {
        return level.color
    }
    return switch metric {
    case .cpuUsage: .cyan
    case .chargeGainPercent: .green
    default: .secondary
    }
}

private func unit(for metric: LiveActivityMetric) -> String {
    switch metric {
    case .chargingPower, .batteryChargingPower: "W"
    case .cpuUsage, .chargeGainPercent: "%"
    case .thermalPressure: ""
    case .downloadSpeed, .uploadSpeed: "KB/s"
    case .socTemperature, .batteryTemperature, .hottestTemperature,
         .chargerTemperature, .wirelessCoilTemperature: "°"
    }
}

private func oneDecimal(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(1)))
}

private func shortValue(
    for metric: LiveActivityMetric,
    state: MiniWattsActivityAttributes.ContentState
) -> String {
    if let rate = networkRate(for: metric, state: state) { return rate.compact }
    if metric == .thermalPressure {
        return state.telemetry?.thermalPressure.map { String(localized: $0.title) } ?? "—"
    }
    guard let value = numericValue(for: metric, state: state) else { return "—" }
    let number = metric == .chargeGainPercent ? "+\(Int(value))" : oneDecimal(value)
    let warning = metric == .chargingPower && state.telemetry?.partialInputWatts != nil ? "!" : ""
    return number + unit(for: metric) + (state.telemetry?.trendSymbol(for: metric) ?? "") + warning
}

private func primaryNumber(for metric: LiveActivityMetric,
                           state: MiniWattsActivityAttributes.ContentState) -> String {
    if let rate = networkRate(for: metric, state: state) { return rate.number }
    guard let value = numericValue(for: metric, state: state) else { return "—" }
    return metric == .chargeGainPercent ? "+\(Int(value))" : oneDecimal(value)
}

private func pressureSymbol(_ pressure: IslandThermalPressure) -> String {
    switch pressure {
    case .nominal: "checkmark.circle"
    case .fair: "thermometer.medium"
    case .serious: "thermometer.high"
    case .critical: "exclamationmark.triangle.fill"
    }
}

private func pressureColor(_ pressure: IslandThermalPressure) -> Color {
    IslandColorLevel.thermal(pressure).color
}

private extension IslandColorLevel {
    var color: Color {
        switch self {
        case .green: .green
        case .yellow: .yellow
        case .red: .red
        case .unavailable: .secondary
        }
    }
}

private struct NetworkRatePresentation {
    let number: String
    let unit: String
    let compact: String
    let roundedCompact: String
}

/// Decimal byte units keep the two compact island slots legible. The direction
/// arrow remains present even in the smallest multi-activity alternative.
private func networkRate(
    for metric: LiveActivityMetric,
    state: MiniWattsActivityAttributes.ContentState
) -> NetworkRatePresentation? {
    let direction: String
    switch metric {
    case .downloadSpeed: direction = "↓"
    case .uploadSpeed: direction = "↑"
    default: return nil
    }
    guard let bytes = numericValue(for: metric, state: state),
          bytes.isFinite, bytes >= 0 else { return nil }
    // Always start at KB/s. Tiny or idle traffic may read 0.0K, but never
    // switch the Live Activity down to a noisy B/s readout.
    let units = ["KB/s", "MB/s", "GB/s"]
    let compactUnits = ["K", "M", "G"]
    var scaled = bytes / 1_000
    var index = 0
    // Switch just before rounding would turn a compact 999K into a wider 1,000K.
    while scaled >= 999.5 && index < units.count - 1 {
        scaled /= 1_000
        index += 1
    }
    let number = scaled < 10
        ? scaled.formatted(.number.precision(.fractionLength(1)))
        : scaled.formatted(.number.precision(.fractionLength(0)))
    let rounded = scaled.formatted(.number.precision(.fractionLength(0)))
    return NetworkRatePresentation(number: number,
                                   unit: units[index],
                                   compact: direction + number + compactUnits[index],
                                   roundedCompact: direction + rounded + compactUnits[index])
}

private struct MinimalValueVariants {
    let preferredWithUnit: String
    let precise: String
    let roundedWithUnit: String
    let rounded: String
}

/// Keep the intrinsic width of each alternative so ViewThatFits moves to the
/// next complete reading instead of accepting a truncated first choice.
private func minimalValueVariants(
    for metric: LiveActivityMetric,
    state: MiniWattsActivityAttributes.ContentState
) -> MinimalValueVariants? {
    if let rate = networkRate(for: metric, state: state) {
        return MinimalValueVariants(preferredWithUnit: rate.compact,
                                    precise: rate.roundedCompact,
                                    roundedWithUnit: rate.compact,
                                    rounded: rate.roundedCompact)
    }
    if metric == .downloadSpeed || metric == .uploadSpeed { return nil }
    guard let value = numericValue(for: metric, state: state), value.isFinite else { return nil }
    if metric == .chargingPower || metric == .batteryChargingPower {
        guard value >= 0, value < 1_000 else { return nil }
    } else if metric == .cpuUsage || metric == .chargeGainPercent {
        guard (0...100).contains(value) else { return nil }
    } else {
        guard value >= -40, value <= 150 else { return nil }
    }
    let precise = metric == .chargeGainPercent ? "+\(Int(value))" : oneDecimal(value)
    let rounded = metric == .chargeGainPercent ? precise : "\(Int(value.rounded()))"
    let suffix = unit(for: metric)
    let preferred = abs(value) < 100 ? precise : rounded
    let trend = state.telemetry?.trendSymbol(for: metric) ?? ""
    return MinimalValueVariants(preferredWithUnit: preferred + suffix + trend,
                                precise: rounded + suffix + trend,
                                roundedWithUnit: rounded + suffix,
                                rounded: rounded)
}

private func formattedValue(
    for metric: LiveActivityMetric,
    state: MiniWattsActivityAttributes.ContentState
) -> String {
    if let rate = networkRate(for: metric, state: state) {
        return "\(rate.number) \(rate.unit)"
    }
    if metric == .thermalPressure {
        return state.telemetry?.thermalPressure.map { String(localized: $0.title) }
            ?? String(localized: "No reading")
    }
    guard numericValue(for: metric, state: state) != nil else {
        return String(localized: "No reading")
    }
    return shortValue(for: metric, state: state)
}
