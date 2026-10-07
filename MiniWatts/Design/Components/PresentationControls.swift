import SwiftUI

struct PresentationStatusRow: View {
    let title: LocalizedStringResource
    let symbol: String
    let tint: Color
    var detail: LocalizedStringResource?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label { Text(title) } icon: { Image(systemName: symbol).foregroundStyle(tint) }
                .font(.subheadline.weight(.semibold))
            if let detail {
                Text(detail).font(.caption).foregroundStyle(Color.mwMuted)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}

/// Larger text stacks the menu below its label instead of squeezing the choice.
struct PresentationPickerRow<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let title: LocalizedStringResource
    @ViewBuilder let content: () -> Content

    init(_ title: LocalizedStringResource, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) { Text(title); selection }
            } else {
                HStack(spacing: 8) {
                    Text(title).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    selection
                }
            }
        }
        .font(.subheadline)
        .frame(minHeight: 44)
    }

    private var selection: some View {
        content().labelsHidden().pickerStyle(.menu).tint(.mwAccent)
    }
}

/// Refresh the clock in this small row, not the whole chart/preview tree.
/// Sample receipt proves freshness, not that a sensor has been calibrated.
struct SampleFreshnessView: View {
    let sampledAt: Date
    let hasSample: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            let state = SampleFreshness.classify(hasSample: hasSample,
                                                 age: context.date.timeIntervalSince(sampledAt))
            VStack(alignment: .leading, spacing: 4) {
                Label { Text(state.title) } icon: { Image(systemName: state.symbol) }
                    .foregroundStyle(state.tint)
                if hasSample {
                    Text("Last sample at \(Formatting.clock(sampledAt))")
                        .foregroundStyle(Color.mwMuted)
                }
            }
            .font(.caption)
            .monospacedDigit()
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }
}

private extension SampleFreshness {
    var title: LocalizedStringResource {
        switch self {
        case .waiting: "Waiting for first sample"
        case .current: "Recent sample received"
        case .delayed: "Readings are delayed"
        case .old: "Readings have not refreshed"
        }
    }
    var symbol: String {
        switch self {
        case .waiting: "hourglass"
        case .current: "checkmark.circle"
        case .delayed, .old: "clock.badge.exclamationmark"
        }
    }
    var tint: Color {
        switch self {
        case .waiting: .mwMuted
        case .current: .mwBattery
        case .delayed, .old: .mwLoss
        }
    }
}
