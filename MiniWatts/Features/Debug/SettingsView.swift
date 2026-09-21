import SwiftUI

struct SettingsView: View {
    @Environment(PowerMonitor.self) private var monitor
    @Environment(\.dismiss) private var dismiss
    @State private var showingProblemReport = false

    var body: some View {
        @Bindable var monitor = monitor
        NavigationStack {
            ZStack {
                Backdrop(glow: .mwAccent, glowIntensity: 0.6)
                ScrollView {
                    VStack(spacing: 14) {
                        diagnosticsPanel
                        recordingPanel(keepAwake: $monitor.keepScreenAwakeWhileCharging)
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
            .sheet(isPresented: $showingProblemReport) { ProblemReportView() }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 8) {
                        Button("Done") { dismiss() }.tint(.mwAccent)
                        AppVersionBadge()
                    }
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
                Text("With this on, the screen stays awake while charging. The floating monitor can continue sensor sampling after MiniWatts enters the background; a Live Activity alone cannot.")
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
                DetailRow(label: "Charge level",
                          value: monitor.snapshot.percent.map { "\($0)% · \(monitor.batteryLevelSource)" })
                DetailRow(label: "Battery sources", value: monitor.batteryLevelCandidates)
                DetailRow(label: "HID sensors",
                          value: monitor.sensorsAvailable
                              ? String(localized: "available") : String(localized: "unavailable"))
                DetailRow(label: "Cycle count", value: monitor.snapshot.cycleCount.map(String.init))
                DetailRow(label: "Battery health",
                          value: monitor.snapshot.healthPercent.map { String(format: "%.0f%%", $0) })
            }
        }
    }

    private var diagnosticsPanel: some View {
        Panel("Diagnostics", systemImage: "stethoscope") {
            VStack(alignment: .leading, spacing: 10) {
                Text("The report stays on this iPhone until you choose where to share it. It contains recent probe state and sensor names, but no serial number or account information.")
                    .font(.caption)
                    .foregroundStyle(Color.mwMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Button { showingProblemReport = true } label: {
                    Label("Problem report", systemImage: "exclamationmark.bubble")
                        .font(.system(size: 14, weight: .semibold))
                }
                .tint(.mwAccent)
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
