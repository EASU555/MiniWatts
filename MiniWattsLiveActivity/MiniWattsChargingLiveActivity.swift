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
                        if context.state.externalConnected != false {
                            Text("Charging")
                                .font(.caption.weight(.semibold))
                        } else {
                            Text("On battery")
                                .font(.caption.weight(.semibold))
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
                    PrimaryMetricView(state: context.state, isStale: context.isStale)
                        .padding(.top, 4)
                }

                DynamicIslandExpandedRegion(.bottom) {
                    ExpandedMetricStrip(state: context.state)
                        .padding(.top, 4)
                }
            } compactLeading: {
                CompactLeadingContent(state: context.state, isStale: context.isStale)
            } compactTrailing: {
                CompactMetricValue(state: context.state)
                    .foregroundStyle(context.isStale
                                     ? Color.secondary : color(for: context.state.selectedMetric))
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
                        .foregroundStyle(color(for: metric))
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
            .keylineTint(color(for: context.state.minimalMetric ?? context.state.selectedMetric))
        }
    }
}

private struct ChargeLockScreenView: View {
    let context: ActivityViewContext<MiniWattsActivityAttributes>

    var body: some View {
        VStack(spacing: 16) {
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
                ExpandedMetricStrip(state: context.state)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding()
        .foregroundStyle(.white)
        .accessibilityElement(children: .combine)
    }
}

private struct PrimaryMetricView: View {
    let state: MiniWattsActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label(for: state.selectedMetric))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(verbatim: networkRate(for: state.selectedMetric, state: state)?.number
                    ?? numericValue(for: state.selectedMetric, state: state).map(oneDecimal)
                    ?? "—")
                    .font(.title2.monospacedDigit().weight(.bold))
                Text(verbatim: networkRate(for: state.selectedMetric, state: state)?.unit
                    ?? unit(for: state.selectedMetric))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(isStale ? Color.secondary : color(for: state.selectedMetric))

            if state.selectedMetric == .chargingPower {
                if state.externalConnected == false {
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
            } else if state.selectedMetric == .hottestTemperature,
                      let name = state.hottestSensorName {
                Text(name)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if state.selectedMetric == .cpuUsage {
                Text("Whole-device average")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if state.selectedMetric == .downloadSpeed
                        || state.selectedMetric == .uploadSpeed {
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

private struct ExpandedMetricStrip: View {
    let state: MiniWattsActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 8) {
            SmallMetric(metric: .chargingPower, state: state)
            SmallMetric(metric: .socTemperature, state: state)
            SmallMetric(metric: .batteryTemperature, state: state)
            SmallMetric(metric: .hottestTemperature, state: state)
        }
    }
}

private struct SmallMetric: View {
    let metric: LiveActivityMetric
    let state: MiniWattsActivityAttributes.ContentState

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: symbol(for: metric))
                .font(.caption2)
                .foregroundStyle(color(for: metric))
            Text(shortLabel(for: metric))
                .font(.system(.caption2, design: .rounded, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(verbatim: shortValue(for: metric, state: state))
                .font(.system(.caption, design: .rounded, weight: .bold))
                .monospacedDigit()
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
                .foregroundStyle(color(for: metric))
                .accessibilityLabel(label(for: metric))
        } else if let metric = (state.leadingItem ?? .statusIcon).metric {
            Text(verbatim: shortValue(for: metric, state: state))
                .font(.caption2.monospacedDigit().weight(.bold))
                .foregroundStyle(color(for: metric))
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
    }
}

private func color(for metric: LiveActivityMetric) -> Color {
    switch metric {
    case .chargingPower: .yellow
    case .socTemperature: .orange
    case .batteryTemperature: .green
    case .hottestTemperature: .red
    case .cpuUsage: .cyan
    case .downloadSpeed: .cyan
    case .uploadSpeed: .mint
    }
}

private func unit(for metric: LiveActivityMetric) -> String {
    switch metric {
    case .chargingPower: "W"
    case .cpuUsage: "%"
    case .downloadSpeed, .uploadSpeed: "B/s"
    case .socTemperature, .batteryTemperature, .hottestTemperature: "°"
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
    guard let value = numericValue(for: metric, state: state) else { return "—" }
    return oneDecimal(value) + unit(for: metric)
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
    let units = ["B/s", "KB/s", "MB/s", "GB/s"]
    let compactUnits = ["B", "K", "M", "G"]
    var scaled = bytes
    var index = 0
    while scaled >= 1_000 && index < units.count - 1 {
        scaled /= 1_000
        index += 1
    }
    let number = scaled < 10 && index > 0
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
    if metric == .chargingPower {
        guard value >= 0, value < 1_000 else { return nil }
    } else if metric == .cpuUsage {
        guard (0...100).contains(value) else { return nil }
    } else {
        guard value >= -40, value <= 150 else { return nil }
    }
    let precise = oneDecimal(value)
    let rounded = "\(Int(value.rounded()))"
    let suffix = unit(for: metric)
    let preferred = abs(value) < 100 ? precise : rounded
    return MinimalValueVariants(preferredWithUnit: preferred + suffix,
                                precise: precise,
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
    guard numericValue(for: metric, state: state) != nil else {
        return String(localized: "No reading")
    }
    return shortValue(for: metric, state: state)
}
