import ActivityKit
import SwiftUI
import WidgetKit

struct ChargeLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ChargeActivityAttributes.self) { context in
            ChargeActivityLockScreenView(context: context)
        } dynamicIsland: { context in
            // The Dynamic Island is always dark.
            let palette = WidgetPalette(.dark)
            let state = context.state
            let tint = palette.tint(for: state)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text(verbatim: state.percentText)
                            .monospacedDigit()
                    } icon: {
                        Image(systemName: state.symbolName)
                            .foregroundStyle(tint)
                    }
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let temperature = state.batteryTemperature {
                        Text(verbatim: Formatting.temperature(temperature))
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(palette.muted)
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    if let watts = state.watts {
                        WattsReadout(watts: watts, tint: tint, palette: palette, size: 28)
                            .opacity(context.isStale ? 0.5 : 1)
                    } else {
                        Text(state.statusTitle)
                            .font(.system(size: 15, weight: .semibold))
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        LevelBar(percent: state.percent, tint: tint, track: palette.track, height: 5)
                        ActivityFootnote(context: context, palette: palette)
                    }
                }
            } compactLeading: {
                Image(systemName: state.symbolName)
                    .foregroundStyle(tint)
            } compactTrailing: {
                Text(verbatim: Self.compactValue(state))
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(context.isStale ? palette.muted : tint)
            } minimal: {
                Image(systemName: state.symbolName)
                    .foregroundStyle(tint)
            }
            .keylineTint(tint)
        }
    }

    /// Power while it is flowing, level otherwise.
    static func compactValue(_ state: ChargeReading) -> String {
        if state.externalConnected, let watts = state.watts {
            return "\(Int(watts.rounded()))W"
        }
        return state.percentText
    }
}

struct ChargeActivityLockScreenView: View {
    @Environment(\.colorScheme) private var scheme
    let context: ActivityViewContext<ChargeActivityAttributes>

    var body: some View {
        let palette = WidgetPalette(scheme)
        let state = context.state
        let tint = palette.tint(for: state)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: state.symbolName)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(tint)
                if state.externalConnected, let watts = state.watts {
                    WattsReadout(watts: watts, tint: tint, palette: palette, size: 34)
                    if let source = state.source {
                        Text(source.caption)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(palette.muted)
                            .lineLimit(1)
                    }
                } else {
                    Text(state.statusTitle)
                        .font(.system(size: 20, weight: .semibold))
                }
                Spacer(minLength: 8)
                Text(verbatim: state.percentText)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            .opacity(context.isStale ? 0.55 : 1)
            LevelBar(percent: state.percent, tint: tint, track: palette.track, height: 6)
            ActivityFootnote(context: context, palette: palette)
        }
        .padding(16)
        .activitySystemActionForegroundColor(tint)
    }
}

/// Status, battery temperature, and when the charge began — or, once the app has
/// stopped updating, a plain statement that the numbers above are paused.
struct ActivityFootnote: View {
    let context: ActivityViewContext<ChargeActivityAttributes>
    let palette: WidgetPalette

    var body: some View {
        HStack(spacing: 6) {
            if context.isStale {
                Label("Paused — open MiniWatts to resume", systemImage: "pause.circle")
                    .foregroundStyle(palette.loss)
            } else {
                Text(context.state.statusTitle)
                if let temperature = context.state.batteryTemperature {
                    Text(verbatim: Formatting.temperature(temperature))
                        .monospacedDigit()
                }
            }
            Spacer(minLength: 6)
            Text("Since \(Text(context.attributes.startedAt, style: .time))")
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(palette.muted)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
}

#Preview("Lock Screen", as: .content, using: ChargeActivityAttributes(startedAt: .now.addingTimeInterval(-1_800), startPercent: 41)) {
    ChargeLiveActivity()
} contentStates: {
    ChargeReading(date: .now, percent: 72, externalConnected: true, isCharging: true,
                  watts: 18.4, source: .charger, batteryTemperature: 33.6)
}
