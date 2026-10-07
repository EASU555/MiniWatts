import SwiftUI
import UIKit

/// Keep daily actions visible; configuration and technical evidence are opt-in.
/// RootView retains the AVKit source independently of these disclosures.
struct LiveActivityControlPanel: View {
    @Environment(PowerMonitor.self) private var monitor
    @Environment(\.openURL) private var openURL
    @State private var showingProblemReport = false
    @State private var showingOptions = false

    var body: some View {
        @Bindable var monitor = monitor
        Panel("Live Activity", systemImage: "platter.filled.top.iphone") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Enable Live Activity", isOn: $monitor.liveActivityEnabled)
                    .tint(.mwAccent)
                    .disabled(!monitor.liveActivitiesAvailable && !monitor.liveActivityEnabled)
                status

                if !monitor.liveActivitiesAvailable {
                    Button("Open iOS Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                    .buttonStyle(.bordered)
                } else if monitor.liveActivityEnabled {
                    Button { monitor.restartLiveActivity() } label: {
                        Label(recoveryActionTitle, systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .buttonStyle(.bordered)
                    .tint(.mwAccent)
                    .accessibilityHint("If the Dynamic Island is missing, request a new activity. An active floating monitor will briefly stop and then resume.")
                }

                DisclosureGroup("Display options", isExpanded: $showingOptions) {
                    if showingOptions { options.padding(.top, 8) }
                }
                .font(.subheadline)
                .tint(.mwAccent)

                Text("Background refresh needs the floating monitor. A Live Activity alone cannot keep sensor sampling active.")
                    .font(.caption)
                    .foregroundStyle(Color.mwMuted)
                    .fixedSize(horizontal: false, vertical: true)

                DisclosureGroup("Help and recovery details") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Choose the compact Dynamic Island's left and right contents independently. For example, use status icon + power, or power + temperature. The right-side choice is also the primary readout when expanded.")
                        Text("When two or three activities share the Dynamic Island, MiniWatts shows one short reading chosen above. iOS decides its position; the left and right choices apply when MiniWatts is alone.")
                        Text("Upload and download speeds count traffic from the whole device over the latest sample, including other apps. The first sample, a network change, or a long pause shows no reading until two adjacent samples are available. K and M mean KB/s and MB/s in the compact island.")
                        Text("Widgets read the sensors themselves whenever iOS refreshes them — usually every 15 to 60 minutes — and straight away when you plug in or unplug with MiniWatts open. Each one says when its numbers were taken.")
                        Text(verbatim: monitor.liveActivityRecoveryDetail)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                        reportButton
                    }
                    .font(.caption)
                    .foregroundStyle(Color.mwMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                }
                .font(.caption)
                if case .failed = monitor.liveActivityRecoveryStatus { reportButton }
            }
        }
        .sheet(isPresented: $showingProblemReport) { ProblemReportView() }
    }

    private var recoveryActionTitle: LocalizedStringKey {
        monitor.liveActivityRecoveryStatus == .restarting ? "Retry recovery" : "Restart Live Activity"
    }

    @ViewBuilder private var status: some View {
        if !monitor.liveActivitiesAvailable {
            PresentationStatusRow(title: "Live Activities are disabled in iOS Settings.",
                                  symbol: "exclamationmark.circle", tint: .mwLoss)
        } else if !monitor.liveActivityEnabled {
            PresentationStatusRow(title: "Live Activity is off", symbol: "pause.circle", tint: .mwMuted)
        } else {
            switch monitor.liveActivityRecoveryStatus {
            case .idle:
                PresentationStatusRow(title: "Waiting for iOS", symbol: "clock", tint: .mwLoss)
            case .restarting:
                PresentationStatusRow(title: "Recovering Live Activity", symbol: "arrow.clockwise", tint: .mwAccent,
                                      detail: "Keep MiniWatts open. An active floating monitor will be restored automatically after recovery.")
            case .running:
                PresentationStatusRow(title: "Live Activity is active", symbol: "checkmark.circle", tint: .mwBattery,
                                      detail: "iOS controls island visibility. If it is missing, restart here even if the Lock Screen card is still visible.")
            case .failed:
                PresentationStatusRow(title: "Live Activity needs attention", symbol: "exclamationmark.triangle", tint: .mwDanger,
                                      detail: "Keep MiniWatts open and retry. If recovery fails again, export a problem report below.")
            }
        }
    }

    private var reportButton: some View {
        Button { showingProblemReport = true } label: {
            Label("Share recovery diagnostics", systemImage: "square.and.arrow.up")
                .frame(minHeight: 44)
        }
        .tint(.mwAccent)
    }

    private var options: some View {
        @Bindable var monitor = monitor
        return VStack(alignment: .leading, spacing: 8) {
            PresentationPickerRow("Left side") {
                Picker("Left side", selection: $monitor.liveActivityLeadingItem) {
                    Text("Status icon").tag(LiveActivityLeadingItem.statusIcon)
                    Text("SoC icon").tag(LiveActivityLeadingItem.socIcon)
                    Text("Battery temperature icon").tag(LiveActivityLeadingItem.batteryTemperatureIcon)
                    Text("Hottest temperature icon").tag(LiveActivityLeadingItem.hottestTemperatureIcon)
                    Text("CPU icon").tag(LiveActivityLeadingItem.cpuIcon)
                    Text("Download icon").tag(LiveActivityLeadingItem.downloadIcon)
                    Text("Upload icon").tag(LiveActivityLeadingItem.uploadIcon)
                    Text("Charging power").tag(LiveActivityLeadingItem.chargingPower)
                    Text("SoC temperature").tag(LiveActivityLeadingItem.socTemperature)
                    Text("Battery temperature").tag(LiveActivityLeadingItem.batteryTemperature)
                    Text("Hottest component").tag(LiveActivityLeadingItem.hottestTemperature)
                    Text("CPU usage").tag(LiveActivityLeadingItem.cpuUsage)
                    Text("Download speed").tag(LiveActivityLeadingItem.downloadSpeed)
                    Text("Upload speed").tag(LiveActivityLeadingItem.uploadSpeed)
                }
            }
            PresentationPickerRow("Right side") {
                Picker("Right side", selection: $monitor.liveActivityMetric) {
                    Text("Charging power").tag(LiveActivityMetric.chargingPower)
                    Text("SoC temperature").tag(LiveActivityMetric.socTemperature)
                    Text("Battery temperature").tag(LiveActivityMetric.batteryTemperature)
                    Text("Hottest component").tag(LiveActivityMetric.hottestTemperature)
                    Text("CPU usage").tag(LiveActivityMetric.cpuUsage)
                    Text("Download speed").tag(LiveActivityMetric.downloadSpeed)
                    Text("Upload speed").tag(LiveActivityMetric.uploadSpeed)
                }
            }
            PresentationPickerRow("Multiple activities") {
                Picker("Multiple activities", selection: $monitor.liveActivityMinimalSelection) {
                    Text("Follow right side").tag(LiveActivityMinimalSelection.followRightSide)
                    Text("Charging power").tag(LiveActivityMinimalSelection.chargingPower)
                    Text("SoC temperature").tag(LiveActivityMinimalSelection.socTemperature)
                    Text("Battery temperature").tag(LiveActivityMinimalSelection.batteryTemperature)
                    Text("Hottest component").tag(LiveActivityMinimalSelection.hottestTemperature)
                    Text("CPU usage").tag(LiveActivityMinimalSelection.cpuUsage)
                    Text("Download speed").tag(LiveActivityMinimalSelection.downloadSpeed)
                    Text("Upload speed").tag(LiveActivityMinimalSelection.uploadSpeed)
                }
            }
            DisclosureGroup("Advanced priority setting") {
                PresentationPickerRow("Relevance score (experimental)") {
                    Picker("Relevance score (experimental)", selection: $monitor.liveActivityRelevanceScore) {
                        Text("1 · Current default").tag(1)
                        Text("0 · Lower relevance").tag(0)
                    }
                    .accessibilityHint("Sends an update to the current Live Activity without restarting it. iOS decides the final position.")
                }
                Text("MiniWatts sends the new score to the current Live Activity immediately. Apple documents this score for ranking multiple activities from the same app; it does not guarantee a change in position next to other apps. When MiniWatts is alone, its display stays the same.")
                    .font(.caption).foregroundStyle(Color.mwMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct FloatingMonitorControlPanel: View {
    @Environment(TelemetryPictureInPictureController.self) private var pictureInPicture
    @State private var showingOptions = false
    @State private var showingProblemReport = false

    var body: some View {
        Panel("Floating monitor", systemImage: "pip") {
            VStack(alignment: .leading, spacing: 12) {
                status
                Button {
                    if pictureInPicture.isActive || pictureInPicture.isStarting { pictureInPicture.stop() }
                    else { pictureInPicture.start() }
                } label: {
                    Label(primaryActionTitle, systemImage: pictureInPicture.isActive || pictureInPicture.isStarting ? "pip.exit" : "pip.enter")
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(.borderedProminent)
                .tint(.mwAccent)
                .disabled(pictureInPicture.isStopping || pictureInPicture.isRepairingLiveActivity
                          || !pictureInPicture.isSupported
                          || (!pictureInPicture.isActive && !pictureInPicture.isStarting && !pictureInPicture.hasSelectedContent))

                if pictureInPicture.contentMode == .hiddenCarrier, pictureInPicture.isActive,
                   !pictureInPicture.isRepairingLiveActivity && !pictureInPicture.isStopping {
                    Button { pictureInPicture.setVisuallyHidden(!pictureInPicture.isVisuallyHidden) } label: {
                        Label(visibilityActionTitle,
                              systemImage: pictureInPicture.isVisuallyHidden ? "rectangle.inset.filled" : "rectangle.compress.vertical")
                            .frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .buttonStyle(.bordered)
                }

                if let errorMessage = pictureInPicture.errorMessage {
                    EmptyNote(text: errorMessage, systemImage: "exclamationmark.circle")
                    recoveryActions
                }
                if !pictureInPicture.hasSelectedContent {
                    EmptyNote(text: "Select at least one item to display.", systemImage: "exclamationmark.circle")
                }

                DisclosureGroup("Content and preview", isExpanded: $showingOptions) {
                    if showingOptions { options.padding(.top, 8) }
                }
                .font(.subheadline)
                .tint(.mwAccent)
                Text(modeDescription)
                    .font(.caption).foregroundStyle(Color.mwMuted)
                    .fixedSize(horizontal: false, vertical: true)
                DisclosureGroup("Help and recovery details") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("The floating monitor redraws once per second. Choose all temperatures or one component; the iOS system thermal state is always shown. Together shows power and temperatures at the same time; Separate pages alternates between them every four seconds.")
                        Text(parkingHelp)
                        Text(verbatim: pictureInPicture.diagnosticSummary)
                            .font(.caption.monospaced()).textSelection(.enabled)
                        recoveryActions
                    }
                    .font(.caption).foregroundStyle(Color.mwMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                }
                .font(.caption)
            }
        }
        .sheet(isPresented: $showingProblemReport) { ProblemReportView() }
    }

    private var primaryActionTitle: LocalizedStringKey {
        if pictureInPicture.isRepairingLiveActivity { return "Recovering Live Activity" }
        if pictureInPicture.isStopping { return "Stopping Picture in Picture" }
        if pictureInPicture.isStarting { return "Cancel start" }
        return pictureInPicture.isActive ? "Stop Picture in Picture" : "Start Picture in Picture"
    }

    private var visibilityActionTitle: LocalizedStringKey {
        pictureInPicture.isVisuallyHidden ? "Restore floating window" : "Hide floating window to 0.1 pt"
    }

    private var modeDescription: LocalizedStringResource {
        pictureInPicture.contentMode == .liveReadings
            ? "Leave MiniWatts after the floating window opens. Close it to stop background sampling."
            : "Hidden mode keeps the floating session running. Use Restore or Stop here when you need it."
    }

    private var parkingHelp: LocalizedStringResource {
        pictureInPicture.contentMode == .liveReadings
            ? "Stop Picture in Picture before changing modes. Swipe the floating monitor to either screen edge when you want to park it."
            : "Start Picture in Picture, then swipe it to either screen edge. MiniWatts hides it automatically when iOS reports that it is parked; if iOS does not report that state, return here and tap Hide floating window to 0.1 pt. Open MiniWatts again to restore or stop it."
    }

    @ViewBuilder private var status: some View {
        if !pictureInPicture.isSupported {
            PresentationStatusRow(title: "Picture in Picture is not supported on this device.", symbol: "exclamationmark.circle", tint: .mwLoss)
        } else if pictureInPicture.isRepairingLiveActivity {
            PresentationStatusRow(title: "Floating monitor temporarily paused", symbol: "arrow.clockwise", tint: .mwAccent,
                                  detail: "Live Activity recovery is in progress. The previous floating-window state will be restored automatically.")
        } else if pictureInPicture.isStopping {
            PresentationStatusRow(title: "Stopping Picture in Picture", symbol: "hourglass", tint: .mwAccent)
        } else if pictureInPicture.isStarting {
            PresentationStatusRow(title: "Opening floating monitor", symbol: "hourglass", tint: .mwAccent,
                                  detail: "Wait for the window to appear before leaving MiniWatts. You can cancel this attempt below.")
        } else if pictureInPicture.isActive {
            PresentationStatusRow(title: pictureInPicture.isVisuallyHidden ? "Floating monitor is hidden" : "Floating monitor is running",
                                  symbol: pictureInPicture.isVisuallyHidden ? "eye.slash" : "pip", tint: .mwBattery)
        } else {
            PresentationStatusRow(title: pictureInPicture.errorMessage == nil ? "Floating monitor is off" : "Floating monitor needs attention",
                                  symbol: pictureInPicture.errorMessage == nil ? "pip" : "exclamationmark.triangle",
                                  tint: pictureInPicture.errorMessage == nil ? .mwMuted : .mwDanger)
        }
    }

    private var recoveryActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { pictureInPicture.resetAndRestart() } label: {
                Label("Reset and reopen floating monitor", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.bordered)
            .disabled(!pictureInPicture.isSupported || !pictureInPicture.hasSelectedContent || pictureInPicture.isRepairingLiveActivity)
            Button { showingProblemReport = true } label: {
                Label("Share recovery diagnostics", systemImage: "square.and.arrow.up")
                    .frame(minHeight: 44)
            }
        }
        .tint(.mwAccent)
    }

    private var options: some View {
        @Bindable var pictureInPicture = pictureInPicture
        return VStack(alignment: .leading, spacing: 12) {
            Toggle("Show live readings in the floating window", isOn: Binding(
                get: { pictureInPicture.contentMode == .liveReadings },
                set: { pictureInPicture.contentMode = $0 ? .liveReadings : .hiddenCarrier }
            ))
            .tint(.mwAccent)
            .disabled(pictureInPicture.keepsSensorSamplingActive || pictureInPicture.isRepairingLiveActivity)
            if pictureInPicture.keepsSensorSamplingActive || pictureInPicture.isRepairingLiveActivity {
                Text("Stop the floating monitor before changing its mode.")
                    .font(.caption).foregroundStyle(Color.mwMuted)
            }
            if pictureInPicture.contentMode == .liveReadings {
                Toggle("Charging power", isOn: $pictureInPicture.showPower).tint(.mwAccent)
                Toggle("Component temperatures", isOn: $pictureInPicture.showTemperatures).tint(.mwAccent)
                if pictureInPicture.showTemperatures {
                    PresentationPickerRow("Temperature display") {
                        Picker("Temperature display", selection: $pictureInPicture.temperatureSelection) {
                            Text("All components").tag(TelemetryTemperatureSelection.all)
                            Text("SoC temperature").tag(TelemetryTemperatureSelection.soc)
                            Text("Battery temperature").tag(TelemetryTemperatureSelection.battery)
                            Text("Charger temperature").tag(TelemetryTemperatureSelection.charger)
                            Text("Hottest component").tag(TelemetryTemperatureSelection.hottest)
                        }
                    }
                }
                if pictureInPicture.showPower && pictureInPicture.showTemperatures {
                    PresentationPickerRow("Layout") {
                        Picker("Layout", selection: $pictureInPicture.layout) {
                            Text("Together").tag(TelemetryPictureInPictureLayout.together)
                            Text("Separate pages").tag(TelemetryPictureInPictureLayout.separatePages)
                        }
                    }
                }
            }
            TelemetryPictureInPictureInlinePreview(controller: pictureInPicture)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityLabel("Picture in Picture preview")
        }
    }
}
