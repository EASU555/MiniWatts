import SwiftUI

struct SettingsView: View {
    @Environment(PowerMonitor.self) private var monitor
    @Environment(TelemetryPictureInPictureController.self) private var pictureInPicture
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var monitor = monitor
        @Bindable var pictureInPicture = pictureInPicture
        NavigationStack {
            ZStack {
                Backdrop(glow: .mwAccent, glowIntensity: 0.6)
                ScrollView {
                    VStack(spacing: 14) {
                        recordingPanel(keepAwake: $monitor.keepScreenAwakeWhileCharging)
                        liveActivityPanel(enabled: $monitor.liveActivityEnabled,
                                          metric: $monitor.liveActivityMetric)
                        pictureInPicturePanel(
                            showPower: $pictureInPicture.showPower,
                            showTemperatures: $pictureInPicture.showTemperatures,
                            layout: $pictureInPicture.layout
                        )
                        capacityPanel(capacity: $monitor.configuredBatteryWattHours)
                        devicePanel
                        aboutPanel
                        #if DEBUG
                        rawDataLink
                        #endif
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
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }.tint(.mwAccent)
                }
            }
        }
    }

    private func pictureInPicturePanel(
        showPower: Binding<Bool>,
        showTemperatures: Binding<Bool>,
        layout: Binding<TelemetryPictureInPictureLayout>
    ) -> some View {
        Panel("Floating monitor", systemImage: "pip") {
            VStack(alignment: .leading, spacing: 12) {
                TelemetryPictureInPicturePreview(controller: pictureInPicture)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                    }
                    .accessibilityLabel("Picture in Picture preview")

                Toggle("Charging power", isOn: showPower)
                    .tint(.mwAccent)
                Toggle("Component temperatures", isOn: showTemperatures)
                    .tint(.mwAccent)

                if showPower.wrappedValue && showTemperatures.wrappedValue {
                    Picker("Layout", selection: layout) {
                        Text("Together").tag(TelemetryPictureInPictureLayout.together)
                        Text("Separate pages").tag(TelemetryPictureInPictureLayout.separatePages)
                    }
                    .pickerStyle(.segmented)
                }

                if !showPower.wrappedValue && !showTemperatures.wrappedValue {
                    EmptyNote(text: "Select at least one item to display.",
                              systemImage: "exclamationmark.circle")
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

                Text("The floating monitor redraws once per second. Together shows power and temperatures at the same time; Separate pages alternates between them every four seconds.")
                    .font(.caption)
                    .foregroundStyle(Color.mwMuted)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Start Picture in Picture here before leaving MiniWatts. Sensor sampling stays active while the floating window is open and stops when you close it.")
                    .font(.caption)
                    .foregroundStyle(Color.mwMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func liveActivityPanel(enabled: Binding<Bool>,
                                   metric: Binding<LiveActivityMetric>) -> some View {
        Panel("Live Activity", systemImage: "platter.filled.top.iphone") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: enabled) {
                    Text("Show charging data on the Lock Screen and Dynamic Island")
                        .font(.subheadline.weight(.medium))
                }
                .tint(.mwAccent)

                HStack {
                    Text("Primary readout")
                        .font(.subheadline)
                    Spacer()
                    Picker("Primary readout", selection: metric) {
                        Text("Charging power").tag(LiveActivityMetric.chargingPower)
                        Text("SoC temperature").tag(LiveActivityMetric.socTemperature)
                        Text("Battery temperature").tag(LiveActivityMetric.batteryTemperature)
                        Text("Hottest component").tag(LiveActivityMetric.hottestTemperature)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }

                Text("The compact Dynamic Island shows this reading. Press and hold it to see power, SoC, battery and hottest-component temperatures together.")
                    .font(.caption)
                    .foregroundStyle(Color.mwMuted)
                    .fixedSize(horizontal: false, vertical: true)

                Text("MiniWatts starts the Live Activity when a charger connects. Unless the floating monitor is running, sensor access pauses when the app is suspended, so an old reading is clearly marked as paused instead of continuing to look live.")
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

    private func recordingPanel(keepAwake: Binding<Bool>) -> some View {
        Panel("Recording", systemImage: "record.circle") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: keepAwake) {
                    Text("Keep the screen on while charging")
                        .font(.system(size: 14, weight: .medium))
                }
                .tint(.mwAccent)
                Text("Sensors are normally read only while MiniWatts is on screen. With this on, the screen is held awake while a charger is connected, never on battery. A running floating monitor is the only background exception.")
                    .font(.caption)
                    .foregroundStyle(Color.mwMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Text("A charge session survives the app being backgrounded: it ends when you unplug, not when you switch away. Any stretch the app missed is left out of the totals rather than estimated, and the session says how much of itself was actually measured.")
                    .font(.caption)
                    .foregroundStyle(Color.mwMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func capacityPanel(capacity: Binding<Double>) -> some View {
        Panel("Battery energy", systemImage: "battery.100.bolt") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(String(format: "%.1f Wh", capacity.wrappedValue))
                        .mwReadout(size: 26)
                        .foregroundStyle(Color.mwAccent)
                    Spacer()
                    Stepper("", value: capacity, in: 5...40, step: 0.1)
                        .labelsHidden()
                }
                Text("Used only for the %-rate estimate, which is the sole way to see discharge power: no discharge-current sensor is exposed to a sandboxed app. Look up your model's rating — an iPhone 17 Pro Max is about 19.7 Wh — and enter it here.")
                    .font(.caption)
                    .foregroundStyle(Color.mwMuted)
                    .fixedSize(horizontal: false, vertical: true)
                if let designCapacity = monitor.snapshot.designCapacity, designCapacity > 0 {
                    EmptyNote(text: "IOKit reported a design capacity of \(designCapacity) mAh on this system, so that value is being used instead.",
                              systemImage: "checkmark.circle")
                }
            }
        }
    }

    private var devicePanel: some View {
        Panel("Device", systemImage: "iphone") {
            VStack(spacing: 0) {
                DetailRow(label: "Model identifier", value: monitor.deviceModelIdentifier)
                DetailRow(label: "System", value: "iOS \(UIDevice.current.systemVersion)")
                DetailRow(label: "HID sensors",
                          value: monitor.sensorsAvailable
                              ? String(localized: "available") : String(localized: "unavailable"))
                DetailRow(label: "Cycle count", value: monitor.snapshot.cycleCount.map(String.init))
                DetailRow(label: "Battery health",
                          value: monitor.snapshot.healthPercent.map { String(format: "%.0f%%", $0) })
            }
        }
    }

    #if DEBUG
    /// Debug builds only, so it is absent from the distributed ipa: the raw dump
    /// is a development tool and nobody should have to explain it to a user. It
    /// stays reachable the way it is actually used — attached to Xcode.
    private var rawDataLink: some View {
        NavigationLink {
            DebugView()
        } label: {
            Panel {
                HStack(spacing: 10) {
                    Image(systemName: "ladybug")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.mwMuted)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Raw data")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text("Every value the probes returned, unedited.")
                            .font(.caption)
                            .foregroundStyle(Color.mwMuted)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.mwMuted)
                }
            }
        }
        .buttonStyle(.plain)
    }
    #endif

    private var aboutPanel: some View {
        Panel("About", systemImage: "info.circle") {
            VStack(alignment: .leading, spacing: 10) {
                Text("MiniWatts reads the phone's own power management sensors through private frameworks — IOKit, IOHIDEventSystemClient and BatteryCenter. Nothing leaves the device and nothing is written outside the app's own container.")
                    .font(.caption)
                    .foregroundStyle(Color.mwMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Those APIs are private, so this build is for sideloading only: it cannot pass App Store review, and any iOS update may change or remove what it reads.")
                    .font(.caption)
                    .foregroundStyle(Color.mwMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
