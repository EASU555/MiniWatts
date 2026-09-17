import SwiftUI

/// High-frequency presentation controls live on the dashboard instead of behind
/// Settings. Keeping them as separate panels preserves the dashboard's existing
/// measurement hierarchy while making recovery and PiP launch one scroll away.
struct LiveActivityControlPanel: View {
    @Environment(PowerMonitor.self) private var monitor

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
                        Text("Charging power").tag(LiveActivityLeadingItem.chargingPower)
                        Text("SoC temperature").tag(LiveActivityLeadingItem.socTemperature)
                        Text("Battery temperature").tag(LiveActivityLeadingItem.batteryTemperature)
                        Text("Hottest component").tag(LiveActivityLeadingItem.hottestTemperature)
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
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }

                if monitor.liveActivityEnabled {
                    Button {
                        monitor.restartLiveActivity()
                    } label: {
                        Label("Restart Live Activity", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.mwAccent)
                }

                Text("Choose the compact Dynamic Island's left and right contents independently. For example, use status icon + power, or power + temperature. The right-side choice is also the primary readout when expanded.")
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
                        if pictureInPicture.isStarting {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: pictureInPicture.isActive ? "pip.exit" : "pip.enter")
                        }
                        Text(pictureInPicture.isActive
                             ? "Stop Picture in Picture" : "Start Picture in Picture")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.mwAccent)
                .disabled(pictureInPicture.isStarting
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
