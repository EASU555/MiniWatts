#if DEBUG
import SwiftUI
import UIKit

/// Everything the probes returned, unedited. This is the page that made the rest
/// of the app possible: sensor names differ between iPhone models, so the way to
/// support a new one is to read the inventory here and extend `SensorCatalog`.
struct DebugView: View {
    @Environment(PowerMonitor.self) private var monitor
    @State private var inventory: [HIDSensors.ServiceInfo] = []
    @State private var copied = false
    @State private var query = ""

    /// Case-insensitive substring match against a row's name and its value. The
    /// lists here run to seventy-odd sensors and dictionaries of fifty keys, which
    /// is not something to read top to bottom looking for one rail.
    private func matches(_ parts: String...) -> Bool {
        guard !query.isEmpty else { return true }
        return parts.contains { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        ZStack {
            Backdrop(glow: .mwMuted, glowIntensity: 0.5)
            ScrollView {
                VStack(spacing: 14) {
                    diagnosticsPanel
                    sensorsPanel
                    inventoryPanel
                    dictionaryPanel("IOPMPowerSource", systemImage: "cpu", dictionary: monitor.snapshot.registry)
                    dictionaryPanel("powerd power source", systemImage: "battery.100", dictionary: monitor.snapshot.powerSource)
                    dictionaryPanel("Adapter details", systemImage: "powerplug", dictionary: monitor.snapshot.adapterDetails)
                    dictionaryPanel("Charge status", systemImage: "pause.circle", dictionary: monitor.snapshot.chargeStatus)
                    powerSourcesPanel
                    batteryCenterPanel
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
        .navigationTitle("Raw data")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: Text("Filter sensors and keys"))
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    UIPasteboard.general.string = fullDump()
                    copied = true
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                }
                .tint(.mwAccent)
            }
        }
    }

    private var diagnosticsPanel: some View {
        Panel("Probes", systemImage: "stethoscope") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(monitor.diagnostics, id: \.self) { line in
                    Text(line).mwMono(size: 11).foregroundStyle(Color.mwMuted)
                }
            }
        }
    }

    private var sensorsPanel: some View {
        Panel("Live sensors", systemImage: "sensor",
              trailing: Text(verbatim: "\(monitor.snapshot.sensors.count)")) {
            if monitor.snapshot.sensors.isEmpty {
                EmptyNote(text: "No sensors returned a finite value.")
            } else {
                VStack(spacing: 0) {
                    ForEach(monitor.snapshot.sensors
                        .filter { matches($0.name, $0.formatted) }
                        .sorted { $0.name < $1.name }) { reading in
                        DetailRow(rawLabel: reading.name, value: reading.formatted)
                    }
                }
            }
        }
    }

    private var inventoryPanel: some View {
        Panel("HID service inventory", systemImage: "list.number",
              trailing: inventory.isEmpty ? nil : Text(verbatim: "\(inventory.count)")) {
            VStack(alignment: .leading, spacing: 10) {
                if inventory.isEmpty {
                    Button {
                        Task { inventory = await monitor.hidInventory() }
                    } label: {
                        Label("Enumerate every HID service", systemImage: "magnifyingglass")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .tint(.mwAccent)
                    EmptyNote(text: "Lists every service the HID event system exposes, matched or not, with its usage page and usage. This is how the power and temperature sensors were found in the first place.")
                } else {
                    ForEach(inventory.filter { matches($0.name, String(format: "0x%04x", $0.usagePage)) }) { service in
                        HStack {
                            Text(service.name).mwMono(size: 11).lineLimit(1)
                            Spacer(minLength: 8)
                            Text(String(format: "0x%04x / %d", service.usagePage, service.usage))
                                .mwMono(size: 10)
                                .foregroundStyle(Color.mwMuted)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }

    private func dictionaryPanel(_ title: LocalizedStringResource, systemImage: String, dictionary: [String: Any]?) -> some View {
        Panel(title, systemImage: systemImage, trailing: dictionary.map { Text("\($0.count) keys") }) {
            if let dictionary, !dictionary.isEmpty {
                VStack(spacing: 0) {
                    ForEach(dictionary.keys.sorted()
                        .filter { matches($0, String(describing: dictionary[$0] ?? "")) }, id: \.self) { key in
                        DetailRow(rawLabel: key, value: String(describing: dictionary[key] ?? ""))
                    }
                }
            } else {
                EmptyNote(text: "Empty. On a device the sandbox filters most of this away; on the simulator it is the Mac's data.")
            }
        }
    }

    /// Every power source powerd will admit to, which is where an accessory would
    /// have to appear for any of this to be reachable without private entitlements.
    private var powerSourcesPanel: some View {
        Panel("powerd power sources", systemImage: "list.bullet.rectangle",
              trailing: Text(verbatim: "\(monitor.powerSources.count)")) {
            if monitor.powerSources.isEmpty {
                EmptyNote(text: "powerd reported no power sources.")
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(monitor.powerSources.enumerated()), id: \.offset) { index, source in
                        VStack(alignment: .leading, spacing: 0) {
                            Text(verbatim: (source["Name"] as? String)
                                 ?? (source["Type"] as? String)
                                 ?? "source \(index)").mwCaption()
                            ForEach(source.keys.sorted()
                                .filter { matches($0, String(describing: source[$0] ?? "")) }, id: \.self) { key in
                                DetailRow(rawLabel: key, value: String(describing: source[key] ?? ""))
                            }
                        }
                    }
                }
            }
        }
    }

    private var batteryCenterPanel: some View {
        Panel("BatteryCenter", systemImage: "square.stack.3d.up",
              trailing: Text("\(monitor.devices.count) devices")) {
            if monitor.devices.isEmpty {
                EmptyNote(text: monitor.batteryCenterDiagnostic ?? "No devices reported.")
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(monitor.devices) { device in
                        VStack(alignment: .leading, spacing: 0) {
                            Text(device.name).mwCaption()
                            ForEach(device.raw.keys.sorted()
                                .filter { matches($0, device.raw[$0] ?? "") }, id: \.self) { key in
                                DetailRow(rawLabel: key, value: device.raw[key])
                            }
                        }
                    }
                }
            }
        }
    }

    private func fullDump() -> String {
        var lines: [String] = ["MiniWatts raw dump — \(Formatting.timestamp(.now))"]
        lines.append(contentsOf: monitor.diagnostics)
        lines.append("\n# Sensors")
        lines.append(contentsOf: monitor.snapshot.sensors.sorted { $0.name < $1.name }.map { "\($0.name) = \($0.formatted)" })
        if !inventory.isEmpty {
            lines.append("\n# HID inventory")
            lines.append(contentsOf: inventory.map { String(format: "%@  0x%04x / %d", $0.name, $0.usagePage, $0.usage) })
        }
        func dump(_ title: String, _ dictionary: [String: Any]?) {
            guard let dictionary, !dictionary.isEmpty else { return }
            lines.append("\n# \(title)")
            lines.append(contentsOf: dictionary.keys.sorted().map { "\($0) = \(String(describing: dictionary[$0]!))" })
        }
        dump("IOPMPowerSource", monitor.snapshot.registry)
        dump("powerd power source", monitor.snapshot.powerSource)
        dump("Adapter details", monitor.snapshot.adapterDetails)
        dump("Charge status", monitor.snapshot.chargeStatus)
        for device in monitor.devices {
            lines.append("\n# BatteryCenter: \(device.name)")
            lines.append(contentsOf: device.raw.keys.sorted().map { "\($0) = \(device.raw[$0] ?? "")" })
        }
        return lines.joined(separator: "\n")
    }
}
#endif
