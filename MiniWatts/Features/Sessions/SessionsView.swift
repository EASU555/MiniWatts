import SwiftUI
import UIKit

extension ChargeSession {
    /// The adapter's own name is hardware and is shown verbatim; the fallback is
    /// copy and is translated. Keeping them apart is why `ChargeSession` exposes
    /// `fallbackTitle` rather than a single pre-rendered `String`.
    var titleText: Text {
        if let adapterName { return Text(verbatim: adapterName) }
        return Text(fallbackTitle)
    }
}

struct SessionsView: View {
    @Environment(PowerMonitor.self) private var monitor
    @State private var confirmingDelete = false

    var body: some View {
        PageScaffold("History", glow: .mwBattery, toolbar: AnyView(toolbar)) {
            switch monitor.historyStorageState {
            case .loading:
                Panel("Loading history", systemImage: "clock.arrow.circlepath") {
                    ProgressView("Checking saved charges")
                }
            case .loadFailed:
                Panel("History could not be read", systemImage: "exclamationmark.triangle") {
                    VStack(alignment: .leading, spacing: 8) {
                        EmptyNote(text: "Saved charges were not erased. Recording is paused until the file can be read; export a problem report if retrying fails.")
                        Button("Retry loading history") { monitor.retryLoadingHistory() }
                            .buttonStyle(.bordered)
                    }
                }
            case .recoveredFromBackup:
                Panel("History recovered", systemImage: "checkmark.shield") {
                    VStack(alignment: .leading, spacing: 8) {
                        EmptyNote(text: "The main history file could not be read, so MiniWatts loaded its safety copy. The newest unsaved readings may be missing.")
                        Button("Retry saving history") { monitor.retrySavingHistory() }
                            .buttonStyle(.bordered)
                    }
                }
            case .saveFailed:
                Panel("History not saved", systemImage: "exclamationmark.triangle") {
                    VStack(alignment: .leading, spacing: 8) {
                        EmptyNote(text: "Current charges are still in memory, but the last disk write failed. MiniWatts will retry during the next charge; export a problem report if this continues.")
                        Button("Retry saving history") { monitor.retrySavingHistory() }
                            .buttonStyle(.bordered)
                    }
                }
            case .backupFailed:
                Panel("History safety copy unavailable", systemImage: "exclamationmark.triangle") {
                    VStack(alignment: .leading, spacing: 8) {
                        EmptyNote(text: "The main history file was saved, but its safety copy could not be updated. MiniWatts will retry on the next save.")
                        Button("Retry saving history") { monitor.retrySavingHistory() }
                            .buttonStyle(.bordered)
                    }
                }
            case .ready:
                EmptyView()
            }
            if let session = monitor.currentSession {
                currentPanel(session)
            }
            if monitor.isLoaded {
                if monitor.sessions.isEmpty {
                    Panel("No finished charges yet", systemImage: "clock.arrow.circlepath") {
                        EmptyNote(text: "A session starts when you plug in and is saved when you unplug. Keep MiniWatts open or use the floating monitor to keep measuring; any missed time is excluded from the totals.",
                                  systemImage: "bolt.badge.clock")
                    }
                } else {
                    summaryPanel
                    ForEach(monitor.sessions) { session in
                        NavigationLink {
                            SessionDetailView(session: session)
                        } label: {
                            SessionRow(session: session)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Open charge details")
                    }
                }
            }
        }
        .confirmationDialog("Delete all saved sessions?",
                            isPresented: $confirmingDelete,
                            titleVisibility: .visible) {
            Button("Delete all", role: .destructive) { monitor.deleteAllSessions() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes all saved sessions and resets any charge recording in progress. This cannot be undone.")
        }
    }

    private var toolbar: some View {
        Button { confirmingDelete = true } label: {
            Label("Delete all saved sessions", systemImage: "trash")
                .labelStyle(.iconOnly)
        }
            .tint(.mwDanger)
            .disabled(monitor.sessions.isEmpty)
    }

    private func currentPanel(_ session: ChargeSession) -> some View {
        Panel("In progress", systemImage: "bolt.fill",
              trailing: Text(verbatim: Formatting.duration(session.duration))) {
            VStack(spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    Metric(caption: "Delivered",
                           value: monitor.sessionTotals.measuredInputWattHours.map { String(format: "%.2f", $0) } ?? "—",
                           unit: "Wh", tint: .mwAccent, size: 21)
                    Metric(caption: "Into cell",
                           value: monitor.sessionTotals.measuredBatteryWattHours.map {
                               String(format: "%.2f", $0)
                           } ?? "—",
                           unit: "Wh", tint: .mwBattery, size: 21)
                    Metric(caption: "Gained",
                           value: session.gainedPercent.map { "+\($0)" } ?? "—",
                           unit: "%", size: 21)
                }
                if !session.samples.isEmpty {
                    SessionPowerChart(samples: session.samples, height: 110)
                        // Totals update every second; recorded samples every five.
                        // Compare only chart inputs, not the entire live session.
                        .equatable()
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(Color.mwAccent.opacity(0.4), lineWidth: 1)
        )
    }

    private var summaryPanel: some View {
        let summary = HistorySummary(sessions: monitor.sessions)
        return Panel("All sessions", systemImage: "sum", trailing: Text(verbatim: "\(monitor.sessions.count)")) {
            HStack(alignment: .top, spacing: 10) {
                Metric(caption: "Delivered",
                       value: summary.measuredInputWattHours.map { String(format: "%.1f", $0) } ?? "—",
                       unit: "Wh", tint: .mwAccent, size: 21)
                Metric(caption: "Into cell",
                       value: summary.measuredBatteryWattHours.map { String(format: "%.1f", $0) } ?? "—",
                       unit: "Wh", tint: .mwBattery, size: 21)
                Metric(caption: "Input to cell",
                       value: summary.inputToCellPercent.map { String(format: "%.0f", $0) } ?? "—",
                       unit: "%", tint: .mwLoss, size: 21)
            }
        }
    }
}

struct SessionRow: View {
    let session: ChargeSession

    private var energySource: LocalizedStringResource {
        if session.totals.measuredInputWattHours != nil { return "From charger" }
        if session.totals.measuredBatteryWattHours != nil { return "Into battery" }
        return "Energy"
    }

    var body: some View {
        Panel {
            VStack(spacing: 10) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        session.titleText
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                        Text("\(Formatting.timestamp(session.start)) · \(Formatting.duration(session.duration))")
                            .mwMono(size: 10)
                            .foregroundStyle(Color.mwMuted)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(energySource)
                            .font(.caption2)
                            .foregroundStyle(Color.mwMuted)
                        Text(verbatim: (session.totals.measuredInputWattHours
                                        ?? session.totals.measuredBatteryWattHours)
                            .map { String(format: "%.2f Wh", $0) } ?? "—")
                            .mwReadout(size: 16)
                            .foregroundStyle(session.totals.measuredInputWattHours == nil
                                             ? Color.mwBattery : Color.mwAccent)
                        Text(verbatim: "\(session.startPercent.map(String.init) ?? "—")% → \(session.endPercent.map(String.init) ?? "—")%")
                            .mwMono(size: 10)
                            .foregroundStyle(Color.mwMuted)
                    }
                }
                Sparkline(samples: session.samples)
                    .frame(height: 26)
                    .accessibilityHidden(true)
                if session.totals.inputToCellPercent != nil || session.throttledFraction > 0.05 || session.isWireless {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { statusPills }
                            .fixedSize(horizontal: true, vertical: false)
                        VStack(alignment: .leading, spacing: 6) { statusPills }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var statusPills: some View {
        if let share = session.totals.inputToCellPercent {
            Pill(text: Text("Input to cell: \(String(format: "%.0f%%", share))"),
                 systemImage: "arrow.triangle.swap", tint: .mwLoss)
        }
        if session.throttledFraction > 0.05 {
            Pill(text: Text("\(String(format: "%.0f%%", session.throttledFraction * 100)) hot"),
                 systemImage: "thermometer.high", tint: .mwDanger)
        }
        if session.isWireless {
            Pill(text: Text("MagSafe"), systemImage: "wave.3.right", tint: .mwWireless)
        }
    }
}

struct SessionDetailView: View {
    let session: ChargeSession
    @Environment(PowerMonitor.self) private var monitor
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDelete = false
    @State private var preparingCSV = false
    @State private var csvFile: SessionShareFile?
    @State private var exportError: String?

    var body: some View {
        ZStack {
            Backdrop(glow: .mwBattery)
            ScrollView {
                VStack(spacing: 14) {
                    energyPanel
                    powerPanel
                    climatePanel
                    detailsPanel
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
                // Pinned to the container's width so nothing inside can widen the
                // scroll content. A paragraph inside an HStack reports an enormous
                // ideal width — the text unwrapped onto one line — and
                // `.frame(maxWidth: .infinity)` only expands, it does not clamp, so
                // that width propagates up and the page starts scrolling sideways.
                .containerRelativeFrame(.horizontal)
            }
        }
        .navigationTitle(session.titleText)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { exportCSV() } label: {
                    if preparingCSV {
                        ProgressView()
                            .accessibilityLabel("Preparing session CSV")
                    } else {
                        Label("Export session CSV", systemImage: "square.and.arrow.up")
                            .labelStyle(.iconOnly)
                    }
                }
                .disabled(preparingCSV || session.isOpen)
                Button(role: .destructive) {
                    confirmingDelete = true
                } label: {
                    Label("Delete session", systemImage: "trash")
                        .labelStyle(.iconOnly)
                }
                .tint(.mwDanger)
                .disabled(preparingCSV)
            }
        }
        .sheet(item: $csvFile) { file in SessionShareSheet(url: file.url) }
        .alert("Could not export session", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: {
            Text(verbatim: exportError ?? "")
        }
        .confirmationDialog("Delete this session?",
                            isPresented: $confirmingDelete,
                            titleVisibility: .visible) {
            Button("Delete session", role: .destructive) {
                monitor.deleteSession(session)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes this saved charge from history. This cannot be undone.")
        }
    }

    private func exportCSV() {
        guard !preparingCSV, !session.isOpen else { return }
        preparingCSV = true
        Task { @MainActor in
            defer { preparingCSV = false }
            do {
                let url = try await SessionCSVExporter.export(session)
                csvFile = SessionShareFile(url: url)
            } catch {
                exportError = error.localizedDescription
            }
        }
    }

    private var energyPanel: some View {
        Panel("Energy", systemImage: "bolt.circle",
              trailing: Text(verbatim: Formatting.duration(session.duration))) {
            VStack(spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    Metric(caption: "Delivered",
                           value: session.totals.measuredInputWattHours.map { String(format: "%.2f", $0) } ?? "—",
                           unit: "Wh", tint: .mwAccent, size: 21)
                    Metric(caption: "Into cell",
                           value: session.totals.measuredBatteryWattHours.map {
                               String(format: "%.2f", $0)
                           } ?? "—",
                           unit: "Wh", tint: .mwBattery, size: 21)
                    Metric(caption: "Not into cell",
                           value: session.totals.measuredNotToCellWattHours.map {
                               String(format: "%.2f", $0)
                           } ?? "—",
                           unit: "Wh", tint: .mwLoss, size: 21)
                }
                HStack(alignment: .top, spacing: 10) {
                    Metric(caption: "Into cell",
                           value: session.totals.measuredBatteryMilliAmpHours.map {
                               String(format: "%.0f", $0)
                           } ?? "—",
                           unit: "mAh", size: 21)
                    Metric(caption: "Input to cell",
                           value: session.totals.inputToCellPercent.map { String(format: "%.0f", $0) } ?? "—",
                           unit: "%", tint: .mwLoss, size: 21)
                    Metric(caption: "Gained",
                           value: session.gainedPercent.map { "+\($0)" } ?? "—",
                           unit: "%", tint: .mwBattery, size: 21)
                }
                if session.totals.integratedSeconds < session.duration * 0.9 {
                    Text("Measured for \(Formatting.duration(session.totals.integratedSeconds)) of \(Formatting.duration(session.duration)) — intervals without valid readings are excluded rather than estimated.")
                        .font(.caption2)
                        .foregroundStyle(Color.mwMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if session.totals.inputIntegratedSeconds > 0,
                   session.totals.batteryIntegratedSeconds > 0,
                   session.totals.pairedIntegratedSeconds == 0 {
                    Text("No simultaneous input and cell readings were recorded, so their share and difference are unavailable.")
                        .font(.caption2)
                        .foregroundStyle(Color.mwMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var powerPanel: some View {
        Panel("Charge curve", systemImage: "chart.xyaxis.line",
              trailing: session.totals.inputIntegratedSeconds > 0
                  ? Text("peak \(String(format: "%.1f", session.peakInputWatts)) W")
                  : Text("peak —")) {
            if session.samples.isEmpty {
                EmptyNote(text: "This session ended before the first sample was written.")
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    SessionPowerChart(samples: session.samples)
                    HStack(spacing: 14) {
                        LegendDot(color: .mwAccent, text: "From charger")
                        LegendDot(color: .mwBattery, text: "Into battery", dashed: true)
                        if session.throttledFraction > 0 {
                            LegendDot(color: .mwDanger.opacity(0.4), text: "Throttled")
                        }
                    }
                }
            }
        }
    }

    private var climatePanel: some View {
        Panel("Level and temperature", systemImage: "thermometer.variable") {
            if session.samples.isEmpty {
                EmptyNote(text: "No samples recorded.")
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    SessionClimateChart(samples: session.samples)
                    HStack(spacing: 14) {
                        LegendDot(color: .mwWireless, text: "Charge %")
                        LegendDot(color: .mwLoss, text: "Battery °C")
                    }
                }
            }
        }
    }

    private var detailsPanel: some View {
        Panel("Details", systemImage: "list.bullet") {
            VStack(spacing: 0) {
                DetailRow(label: "Started", value: Formatting.timestamp(session.start))
                DetailRow(label: "Ended", value: session.end.map(Formatting.timestamp))
                DetailRow(label: "Adapter", value: session.adapterName)
                DetailRow(label: "Rated", value: session.adapterRatedWatts.map { String(format: "%.0f W", $0) })
                DetailRow(
                    label: "Peak from charger",
                    value: session.totals.inputIntegratedSeconds > 0
                        ? String(format: "%.2f W", session.peakInputWatts)
                        : nil
                )
                DetailRow(
                    label: "Peak into cell",
                    value: session.totals.batteryIntegratedSeconds > 0
                        ? String(format: "%.2f W", session.peakBatteryWatts)
                        : nil
                )
                DetailRow(label: "Peak cell temp", value: session.peakBatteryTemperature.map { String(format: "%.1f °C", $0) })
                DetailRow(label: "Average in", value: session.totals.averageInputWatts.map { String(format: "%.2f W", $0) })
                DetailRow(label: "Adapter coverage", value: Formatting.duration(session.totals.inputIntegratedSeconds))
                DetailRow(label: "Battery coverage", value: Formatting.duration(session.totals.batteryIntegratedSeconds))
                DetailRow(label: "Throttled", value: Formatting.duration(session.throttledSeconds))
                DetailRow(label: "Samples", value: "\(session.samples.count)")
                DetailRow(label: "Transport", value: DetailRow.transportName(wireless: session.isWireless))
            }
        }
    }
}

private struct SessionShareFile: Identifiable {
    let url: URL
    var id: URL { url }
}

private struct SessionShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
