import Charts
import SwiftUI

struct TemperatureCurvePanel: View {
    let history: TemperatureHistoryController
    @AppStorage("temperatureCurveComponent") private var component = TemperatureComponent.batteryTemperature
    @AppStorage("temperatureCurveRange") private var range = TemperatureCurveRange.tenMinutes
    @AppStorage("temperatureCurveCompare") private var compare = false
    @State private var plot: TemperatureCurvePlot?
    @State private var selectedDate: Date?
    @State private var visible = false
    @State private var confirmingClear = false

    nonisolated private struct Request: Hashable, Sendable {
        let revision: Int
        let component: TemperatureComponent
        let range: TemperatureCurveRange
        let compare: Bool
        let visible: Bool
    }

    private var recordingTitle: LocalizedStringResource {
        history.isRecording ? "Recording temperatures" : "Temperature recording paused"
    }

    var body: some View {
        let request = Request(revision: history.revision, component: component, range: range,
                              compare: compare, visible: visible)
        Panel("Temperature curves", systemImage: "chart.xyaxis.line") {
            VStack(alignment: .leading, spacing: 12) {
                controls
                if let plot, !plot.points.isEmpty {
                    TemperatureHistoryChart(plot: plot, selectedDate: $selectedDate)
                    inspectedReading(plot)
                    if compare { legend(plot) }
                    if let summary = plot.summaries[component] { statistics(summary) }
                } else if history.storageState == .loading {
                    ProgressView("Loading temperature history")
                        .frame(maxWidth: .infinity, minHeight: 160)
                } else {
                    EmptyNote(text: "No temperature points for this component and time range yet. Recording begins with this version; older curves cannot be reconstructed.",
                              systemImage: "thermometer.medium")
                        .frame(minHeight: 128)
                }
                storageStatus
                Label { Text(recordingTitle) } icon: {
                    Image(systemName: history.isRecording ? "record.circle" : "pause.circle")
                }
                    .font(.caption).foregroundStyle(history.isRecording ? Color.mwBattery : Color.mwMuted)
                if let date = history.records.last?.date {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Last recorded")
                        Spacer()
                        Text(date, format: .dateTime.month().day().hour().minute().second())
                            .monospacedDigit()
                    }
                    .font(.caption2).foregroundStyle(Color.mwMuted)
                }
                DisclosureGroup("Recording and curve details") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Stores one observed frame about every five seconds and retains the latest 24 hours on this iPhone. Foreground sampling or the existing floating monitor is required; suspended time stays blank. The newest uncheckpointed frames may be lost after a force quit.")
                        Text("Drag on the chart to inspect an actual time and temperature. Gaps mark missing readings, sampling pauses or source changes; no line connects them. Long-range plots reduce drawing density while keeping peaks and valleys. Statistics use the original recorded readings.")
                        Text("The latest trend uses the same one-minute warm-up and algorithm as the island. A temperature trend does not validate the sensor's absolute accuracy. Hottest and SoC readings can change source; battery uses the same representative reading as the rest of MiniWatts.")
                        Button(role: .destructive) { confirmingClear = true } label: {
                            Label("Clear temperature history", systemImage: "trash")
                                .frame(minHeight: 44)
                        }
                        .disabled(!history.canClear)
                    }
                    .font(.caption).foregroundStyle(Color.mwMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                }
                .font(.caption).tint(.mwAccent)
            }
        }
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .onChange(of: component) { _, _ in selectedDate = nil }
        .onChange(of: range) { _, _ in selectedDate = nil }
        .onChange(of: compare) { _, _ in selectedDate = nil }
        .task(id: request) {
            guard visible else { return }
            let records = history.records
            let result = await Task.detached(priority: .userInitiated) {
                TemperatureCurvePlot.make(records: records, component: request.component,
                                           range: request.range, compare: request.compare)
            }.value
            guard !Task.isCancelled else { return }
            plot = result
        }
        .confirmationDialog("Clear temperature history?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Clear temperature history", role: .destructive) {
                selectedDate = nil
                history.clear()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes saved temperature curves and their safety copy. Charging history is not affected. New temperature points will continue to be recorded.")
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Component").font(.subheadline)
                Spacer(minLength: 8)
                Picker("Component", selection: $component) {
                    ForEach(TemperatureComponent.allCases) { channel in Text(channel.title).tag(channel) }
                }
                .pickerStyle(.menu).tint(.mwAccent)
            }
            Picker("Curve time range", selection: $range) {
                ForEach(TemperatureCurveRange.allCases) { duration in Text(duration.title).tag(duration) }
            }
            .pickerStyle(.segmented)
            Toggle("Compare component curves", isOn: $compare)
                .font(.subheadline).tint(.mwAccent)
        }
    }

    private func inspectedReading(_ plot: TemperatureCurvePlot) -> some View {
        let inspected = if let selectedDate { plot.nearest(to: selectedDate) } else { plot.records.last }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(component.title).font(.caption).foregroundStyle(Color.mwMuted)
                Spacer()
                Text(verbatim: inspected?.value(component).map { $0.formatted(.number.precision(.fractionLength(1))) + " °C" } ?? "—")
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .foregroundStyle(temperatureCurveColor(component))
            }
            if let inspected {
                Text(inspected.date, format: .dateTime.month().day().hour().minute().second())
                    .font(.caption2.monospacedDigit()).foregroundStyle(Color.mwMuted)
            } else {
                Text("No sample at this time").font(.caption2).foregroundStyle(Color.mwMuted)
            }
            if selectedDate == nil, history.isRecording,
               history.records.last.map({ Date.now.timeIntervalSince($0.date) <= 10 }) == true,
               let rate = history.latestRates[component.rawValue], rate.isFinite {
                HStack(spacing: 4) {
                    Text("Latest trend")
                    Text(verbatim: (rate > 0.15 ? "↑ " : rate < -0.15 ? "↓ " : "→ ")
                         + rate.formatted(.number.precision(.fractionLength(1))) + " °C/min")
                }
                .font(.caption).foregroundStyle(Color.mwMuted)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func statistics(_ summary: TemperatureCurveSummary) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), alignment: .leading)], alignment: .leading, spacing: 8) {
            statistic("Lowest", value: summary.minimum, signed: false)
            statistic("Highest", value: summary.maximum, signed: false)
            statistic("End-to-start change", value: summary.last - summary.first, signed: true)
        }
    }

    private func statistic(_ title: LocalizedStringResource, value: Double, signed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption2).foregroundStyle(Color.mwMuted)
            Text(verbatim: (signed && value > 0 ? "+" : "")
                 + value.formatted(.number.precision(.fractionLength(1))) + " °C")
                .font(.subheadline.monospacedDigit().weight(.semibold))
        }
        .accessibilityElement(children: .combine)
    }

    private func legend(_ plot: TemperatureCurvePlot) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), alignment: .leading)], alignment: .leading, spacing: 8) {
            ForEach(TemperatureComponent.allCases.filter { plot.summaries[$0] != nil }) { channel in
                Label { Text(channel.title) } icon: {
                    Image(systemName: "waveform.path").foregroundStyle(temperatureCurveColor(channel))
                }
                .font(.caption2).foregroundStyle(Color.mwMuted)
            }
        }
    }

    @ViewBuilder private var storageStatus: some View {
        switch history.storageState {
        case .loading, .ready: EmptyView()
        case .recovered:
            EmptyNote(text: "Temperature history was recovered from its safety copy. The newest unsaved frames may be missing.")
        case .loadFailed:
            EmptyNote(text: "Saved temperature history could not be read and was not erased. New readings remain in memory until loading succeeds.", systemImage: "exclamationmark.triangle")
            Button("Retry temperature history") { history.retry() }.buttonStyle(.bordered)
        case .saveFailed, .backupFailed:
            EmptyNote(text: "Temperature history or its safety copy could not be saved. Current curves are still in memory; retry saving before closing MiniWatts.", systemImage: "exclamationmark.triangle")
            Button("Retry temperature history") { history.retry() }.buttonStyle(.bordered)
        }
    }
}

private struct TemperatureHistoryChart: View {
    let plot: TemperatureCurvePlot
    @Binding var selectedDate: Date?

    var body: some View {
        Chart {
            ForEach(plot.points) { point in
                LineMark(x: .value("Time", point.date), y: .value("Celsius", point.value),
                         series: .value("Segment", point.series))
                    .foregroundStyle(temperatureCurveColor(point.component))
                    .lineStyle(StrokeStyle(lineWidth: 1.8, lineJoin: .round, dash: temperatureCurveDash(point.component)))
                    .interpolationMethod(.linear)
                    .accessibilityLabel(Text(point.component.title))
            }
            ForEach(plot.singletons) { point in
                PointMark(x: .value("Time", point.date), y: .value("Celsius", point.value))
                    .foregroundStyle(temperatureCurveColor(point.component))
                    .symbolSize(12)
                    .accessibilityLabel(Text(point.component.title))
            }
            if let selectedDate {
                RuleMark(x: .value("Time", selectedDate)).foregroundStyle(Color.mwMuted.opacity(0.6))
            }
        }
        .chartXScale(domain: plot.domain)
        .chartYScale(domain: plot.temperatures)
        .chartXSelection(value: $selectedDate)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(Color.mwGrid)
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(date, format: .dateTime.hour().minute()).font(.caption2).foregroundStyle(Color.mwMuted)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(Color.mwGrid)
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(verbatim: number.formatted(.number.precision(.fractionLength(0))) + "°C")
                            .font(.caption2).foregroundStyle(Color.mwMuted)
                    }
                }
            }
        }
        .chartLegend(.hidden)
        .frame(height: 192)
        .accessibilityLabel("Temperature curves")
        .accessibilityHint("Drag to inspect a recorded time. Blank areas have no continuous temperature record.")
    }
}

private func temperatureCurveColor(_ component: TemperatureComponent) -> Color {
    switch component {
    case .batteryTemperature: .mwBattery
    case .socTemperature: .mwAccent
    case .chargerTemperature: .mwLoss
    case .wirelessCoilTemperature: .mwWireless
    case .hottestTemperature: .mwDanger
    }
}

private func temperatureCurveDash(_ component: TemperatureComponent) -> [CGFloat] {
    switch component {
    case .batteryTemperature: []
    case .socTemperature: [6, 3]
    case .chargerTemperature: [2, 3]
    case .wirelessCoilTemperature: [8, 3, 2, 3]
    case .hottestTemperature: [10, 3]
    }
}
