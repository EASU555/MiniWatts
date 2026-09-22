import SwiftUI

/// High-frequency presentation controls live on the dashboard instead of behind
/// Settings. Keeping them as separate panels preserves the dashboard's existing
/// measurement hierarchy while making recovery and PiP launch one scroll away.
struct LiveActivityControlPanel: View {
    @Environment(PowerMonitor.self) private var monitor
    @State private var showingProblemReport = false

    var body: some View {
        @Bindable var monitor = monitor

        Panel("Live Activity", systemImage: "platter.filled.top.iphone") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: $monitor.liveActivityEnabled) {
                    Text("Show charging data on the Lock Screen and Dynamic Island")
                        .font(.subheadline.weight(.medium))
                }
                .tint(.mwAccent)

                HStack {
                    Text("Left side")
                        .font(.subheadline)
                    Spacer()
                    Picker("Left side", selection: $monitor.liveActivityLeadingItem) {
                        Text("Status icon").tag(LiveActivityLeadingItem.statusIcon)
                        Text("SoC icon").tag(LiveActivityLeadingItem.socIcon)
                        Text("Battery temperature icon").tag(LiveActivityLeadingItem.batteryTemperatureIcon)
                        Text("Hottest temperature icon").tag(LiveActivityLeadingItem.hottestTemperatureIcon)
                        Text("CPU icon").tag(LiveActivityLeadingItem.cpuIcon)
                        Text("Charging power").tag(LiveActivityLeadingItem.chargingPower)
                        Text("SoC temperature").tag(LiveActivityLeadingItem.socTemperature)
                        Text("Battery temperature").tag(LiveActivityLeadingItem.batteryTemperature)
                        Text("Hottest component").tag(LiveActivityLeadingItem.hottestTemperature)
                        Text("CPU usage").tag(LiveActivityLeadingItem.cpuUsage)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }

                HStack {
                    Text("Right side")
                        .font(.subheadline)
                    Spacer()
                    Picker("Right side", selection: $monitor.liveActivityMetric) {
                        Text("Charging power").tag(LiveActivityMetric.chargingPower)
                        Text("SoC temperature").tag(LiveActivityMetric.socTemperature)
                        Text("Battery temperature").tag(LiveActivityMetric.batteryTemperature)
                        Text("Hottest component").tag(LiveActivityMetric.hottestTemperature)
                        Text("CPU usage").tag(LiveActivityMetric.cpuUsage)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }

                HStack {
                    Text("Multiple activities")
                        .font(.subheadline)
                    Spacer()
                    Picker("Multiple activities", selection: $monitor.liveActivityMinimalSelection) {
                        Text("Follow right side").tag(LiveActivityMinimalSelection.followRightSide)
                        Text("Charging power").tag(LiveActivityMinimalSelection.chargingPower)
                        Text("SoC temperature").tag(LiveActivityMinimalSelection.socTemperature)
                        Text("Battery temperature").tag(LiveActivityMinimalSelection.batteryTemperature)
                        Text("Hottest component").tag(LiveActivityMinimalSelection.hottestTemperature)
                        Text("CPU usage").tag(LiveActivityMinimalSelection.cpuUsage)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }

                HStack {
                    Text("Relevance score (experimental)")
                        .font(.subheadline)
                    Spacer()
                    Picker("Relevance score (experimental)", selection: $monitor.liveActivityRelevanceScore) {
                        Text("1 · Current default").tag(1)
                        Text("0 · Lower relevance").tag(0)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .accessibilityHint("Sends an update to the current Live Activity without restarting it. iOS decides the final position.")
                }

                Text("MiniWatts sends the new score to the current Live Activity immediately. Apple documents this score for ranking multiple activities from the same app; it does not guarantee a change in position next to other apps. When MiniWatts is alone, its display stays the same.")
                    .font(.caption)
                    .foregroundStyle(Color.mwMuted)
                    .fixedSize(horizontal: false, vertical: true)

                if monitor.liveActivityEnabled {
                    Button {
                        monitor.restartLiveActivity()
                    } label: {
                        HStack(spacing: 8) {
                            if monitor.liveActivityRecoveryStatus == .restarting {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Restarting Live Activity")
                            } else {
                                Label("Restart Live Activity", systemImage: "arrow.clockwise")
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.mwAccent)
                    .disabled(monitor.liveActivityRecoveryStatus == .restarting)
                }

                if case .failed = monitor.liveActivityRecoveryStatus {
                    EmptyNote(
                        text: "Live Activity could not be restarted. Keep MiniWatts open and try again. If this repeats, check Live Activities in iOS Settings.",
                        systemImage: "exclamationmark.triangle"
                    )
                }

                DisclosureGroup("Live Activity recovery details") {
                    Text(verbatim: monitor.liveActivityRecoveryDetail)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button { showingProblemReport = true } label: {
                        Label("Share recovery diagnostics", systemImage: "square.and.arrow.up")
                    }
                }
                .font(.caption)

                Text("Choose the compact Dynamic Island's left and right contents independently. For example, use status icon + power, or power + temperature. The right-side choice is also the primary readout when expanded.")
                    .font(.caption)
                    .foregroundStyle(Color.mwMuted)
                    .fixedSize(horizontal: false, vertical: true)

                Text("When two or three activities share the Dynamic Island, MiniWatts shows one short reading chosen above. iOS decides its position; the left and right choices apply when MiniWatts is alone.")
                    .font(.caption)
                    .foregroundStyle(Color.mwMuted)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Turning this on starts the Live Activity immediately. It refreshes while MiniWatts is open, or in the background while the floating monitor is running. A Live Activity by itself doesn't keep sensor sampling active.")
                    .font(.caption)
                    .foregroundStyle(Color.mwMuted)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Widgets read the sensors themselves whenever iOS refreshes them — usually every 15 to 60 minutes — and straight away when you plug in or unplug with MiniWatts open. Each one says when its numbers were taken.")
                    .font(.caption)
                    .foregroundStyle(Color.mwMuted)
                    .fixedSize(horizontal: false, vertical: true)

                if !monitor.liveActivitiesAvailable {
                    EmptyNote(text: "Live Activities are disabled in iOS Settings.",
                              systemImage: "exclamationmark.circle")
                }
            }
        }
        .sheet(isPresented: $showingProblemReport) { ProblemReportView() }
    }
}

struct FloatingMonitorControlPanel: View {
    @Environment(TelemetryPictureInPictureController.self) private var pictureInPicture

    var body: some View {
        @Bindable var pictureInPicture = pictureInPicture

        Panel("Floating monitor", systemImage: "pip") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Show live readings in the floating window", isOn: Binding(
                    get: { pictureInPicture.contentMode == .liveReadings },
                    set: { pictureInPicture.contentMode = $0 ? .liveReadings : .hiddenCarrier }
                ))
                .tint(.mwAccent)
                .disabled(pictureInPicture.keepsSensorSamplingActive)

                TelemetryPictureInPictureInlinePreview(controller: pictureInPicture)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                    }
                    .accessibilityLabel("Picture in Picture preview")

                if pictureInPicture.contentMode == .liveReadings {
                    Toggle("Charging power", isOn: $pictureInPicture.showPower)
                        .tint(.mwAccent)
                    Toggle("Component temperatures", isOn: $pictureInPicture.showTemperatures)
                        .tint(.mwAccent)

                    if pictureInPicture.showTemperatures {
                        HStack {
                            Text("Temperature display")
                                .font(.subheadline)
                            Spacer()
                            Picker("Temperature display",
                                   selection: $pictureInPicture.temperatureSelection) {
                                Text("All components").tag(TelemetryTemperatureSelection.all)
                                Text("SoC temperature").tag(TelemetryTemperatureSelection.soc)
                                Text("Battery temperature").tag(TelemetryTemperatureSelection.battery)
                                Text("Charger temperature").tag(TelemetryTemperatureSelection.charger)
                                Text("Hottest component").tag(TelemetryTemperatureSelection.hottest)
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                        }
                    }

                    if pictureInPicture.showPower && pictureInPicture.showTemperatures {
                        Picker("Layout", selection: $pictureInPicture.layout) {
                            Text("Together").tag(TelemetryPictureInPictureLayout.together)
                            Text("Separate pages").tag(TelemetryPictureInPictureLayout.separatePages)
                        }
                        .pickerStyle(.segmented)
                    }

                    if !pictureInPicture.showPower && !pictureInPicture.showTemperatures {
                        EmptyNote(text: "Select at least one item to display.",
                                  systemImage: "exclamationmark.circle")
                    }
                } else {
                    EmptyNote(text: "Hidden carrier mode uses the system video-call Picture in Picture container. After it is parked at the screen edge, MiniWatts shrinks it to 0.1 pt so no PlayerLayer line remains.",
                              systemImage: "pip")

                    if pictureInPicture.isActive {
                        Button {
                            pictureInPicture.setVisuallyHidden(
                                !pictureInPicture.isVisuallyHidden
                            )
                        } label: {
                            Label(
                                pictureInPicture.isVisuallyHidden
                                    ? "Restore floating window"
                                    : "Hide floating window to 0.1 pt",
                                systemImage: pictureInPicture.isVisuallyHidden
                                    ? "rectangle.inset.filled"
                                    : "rectangle.compress.vertical"
                            )
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(.mwAccent)
                    }
                }

                Button {
                    if pictureInPicture.isActive {
                        pictureInPicture.stop()
                    } else {
                        pictureInPicture.start()
                    }
                } label: {
                    HStack(spacing: 8) {
                        if pictureInPicture.isStarting || pictureInPicture.isStopping {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: pictureInPicture.isActive ? "pip.exit" : "pip.enter")
                        }
                        if pictureInPicture.isStopping {
                            Text("Stopping Picture in Picture")
                        } else {
                            Text(pictureInPicture.isActive
                                 ? "Stop Picture in Picture" : "Start Picture in Picture")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.mwAccent)
                .disabled(pictureInPicture.isStarting
                          || pictureInPicture.isStopping
                          || !pictureInPicture.isSupported
                          || (!pictureInPicture.isActive
                              && !pictureInPicture.hasSelectedContent))

                if !pictureInPicture.isSupported {
                    EmptyNote(text: "Picture in Picture is not supported on this device.",
                              systemImage: "exclamationmark.circle")
                }

                if let errorMessage = pictureInPicture.errorMessage {
                    EmptyNote(text: errorMessage, systemImage: "exclamationmark.circle")
                }

                if pictureInPicture.contentMode == .liveReadings {
                    Text("The floating monitor redraws once per second. Choose all temperatures or one component; the iOS system thermal state is always shown. Together shows power and temperatures at the same time; Separate pages alternates between them every four seconds.")
                        .font(.caption)
                        .foregroundStyle(Color.mwMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("Start Picture in Picture here before leaving MiniWatts. Sensor sampling stays active while the floating window is open and stops when you close it.")
                    .font(.caption)
                    .foregroundStyle(Color.mwMuted)
                    .fixedSize(horizontal: false, vertical: true)

                Text(pictureInPicture.contentMode == .liveReadings
                     ? "Stop Picture in Picture before changing modes. Swipe the floating monitor to either screen edge when you want to park it."
                     : "Start Picture in Picture, then swipe it to either screen edge. MiniWatts hides it automatically when iOS reports that it is parked; if iOS does not report that state, return here and tap Hide floating window to 0.1 pt. Open MiniWatts again to restore or stop it.")
                    .font(.caption)
                    .foregroundStyle(Color.mwMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
