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
                        Text("Charging")
                            .font(.caption.weight(.semibold))
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
                Image(systemName: context.isStale
                      ? "pause.fill" : symbol(for: context.state.selectedMetric))
                    .foregroundStyle(context.isStale
                                     ? Color.secondary : color(for: context.state.selectedMetric))
                    .accessibilityHidden(true)
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
                Image(systemName: context.isStale
                      ? "pause.fill" : symbol(for: context.state.selectedMetric))
                    .foregroundStyle(context.isStale
                                     ? Color.secondary : color(for: context.state.selectedMetric))
                    .accessibilityLabel(minimalAccessibilityLabel(isStale: context.isStale))
            }
            .keylineTint(color(for: context.state.selectedMetric))
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
                Text(verbatim: numericValue(for: state.selectedMetric, state: state)
                    .map(oneDecimal) ?? "—")
                    .font(.title2.monospacedDigit().weight(.bold))
                Text(verbatim: unit(for: state.selectedMetric))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(isStale ? Color.secondary : color(for: state.selectedMetric))

            if state.selectedMetric == .chargingPower {
                if state.powerIsBatterySide {
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
    }
}

private func label(for metric: LiveActivityMetric) -> LocalizedStringKey {
    switch metric {
    case .chargingPower: "Charging power"
    case .socTemperature: "SoC temperature"
    case .batteryTemperature: "Battery temperature"
    case .hottestTemperature: "Hottest component"
    }
}

private func shortLabel(for metric: LiveActivityMetric) -> LocalizedStringKey {
    switch metric {
    case .chargingPower: "Power"
    case .socTemperature: "SoC"
    case .batteryTemperature: "Battery"
    case .hottestTemperature: "Hottest"
    }
}

private func minimalAccessibilityLabel(isStale: Bool) -> LocalizedStringKey {
    isStale ? "Reading paused" : "MiniWatts"
}

private func symbol(for metric: LiveActivityMetric) -> String {
    switch metric {
    case .chargingPower: "bolt.fill"
    case .socTemperature: "cpu"
    case .batteryTemperature: "battery.75percent"
    case .hottestTemperature: "thermometer.high"
    }
}

private func color(for metric: LiveActivityMetric) -> Color {
    switch metric {
    case .chargingPower: .yellow
    case .socTemperature: .orange
    case .batteryTemperature: .green
    case .hottestTemperature: .red
    }
}

private func unit(for metric: LiveActivityMetric) -> String {
    metric == .chargingPower ? "W" : "°"
}

private func oneDecimal(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(1)))
}

private func shortValue(
    for metric: LiveActivityMetric,
    state: MiniWattsActivityAttributes.ContentState
) -> String {
    guard let value = numericValue(for: metric, state: state) else { return "—" }
    return oneDecimal(value) + unit(for: metric)
}

private func formattedValue(
    for metric: LiveActivityMetric,
    state: MiniWattsActivityAttributes.ContentState
) -> String {
    guard let value = numericValue(for: metric, state: state) else {
        return String(localized: "No reading")
    }
    return shortValue(for: metric, state: state)
}
