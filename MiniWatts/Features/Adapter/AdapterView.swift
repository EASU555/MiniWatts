import SwiftUI

struct AdapterView: View {
    @Environment(PowerMonitor.self) private var monitor

    private var snapshot: PowerSnapshot { monitor.snapshot }

    var body: some View {
        PageScaffold("Adapter", glow: snapshot.isWirelessInput ? .mwWireless : .mwAccent) {
            if snapshot.externalConnected {
                headlinePanel
                identityPanel
                profilesPanel
                railsPanel
            } else {
                Panel("Not connected", systemImage: "powerplug") {
                    EmptyNote(text: "Plug in a charger to read its handshake. USB-PD adapters advertise a menu of voltage/current profiles; the phone picks one and this page shows which, alongside what is actually flowing.",
                              systemImage: "cable.connector")
                }
                railsPanel
            }
        }
    }

    // MARK: Headline

    private var headlinePanel: some View {
        Panel("Draw vs rating", systemImage: "gauge.with.dots.needle.67percent",
              trailing: snapshot.adapterSource.map { Text(verbatim: $0) }) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(snapshot.inputWatts.map(Formatting.watts) ?? "—")
                        .mwReadout(size: snapshot.inputWatts == nil ? 30 : 44)
                        .foregroundStyle(snapshot.inputWatts == nil ? Color.mwMuted.opacity(0.55) : Color.mwAccent)
                    Text(verbatim: "W")
                        .font(.system(size: 18, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.mwMuted)
                    Text("of")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.mwMuted)
                        .padding(.horizontal, 2)
                    Text(snapshot.adapterRatedWatts.map { String(format: "%.0f", $0) } ?? "—")
                        .mwReadout(size: 26)
                    Text("W rated")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.mwMuted)
                }

                if let utilisation = snapshot.adapterUtilisation {
                    BarRow(title: Text("Adapter utilisation"),
                           detail: "\(Int(utilisation * 100))%",
                           fraction: utilisation,
                           tint: utilisation > 0.75 ? .mwBattery : .mwLoss)
                }

                if snapshot.inputWatts == nil, snapshot.adapterIsWireless {
                    EmptyNote(text: "Wireless charging has no input-current sensor, so there is nothing to compare against the rating. The voltage and current below are the profile the pad negotiated — a ceiling that stays put while the actual draw moves.",
                              systemImage: "wave.3.right")
                } else if let reason = headroomReason {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(Color.mwMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if snapshot.inputWatts != nil {
                    Text("Live input power uses the phone's Charger VQ0u and IQ0u sensors, not the charger's display. Their meaning on a new device model must be checked against raw readings before correcting the number.")
                        .font(.caption2)
                        .foregroundStyle(Color.mwMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// The interesting question on this page is why the phone is not pulling the
    /// full rating, so the most likely explanation is spelled out rather than left
    /// for the user to infer from four separate numbers.
    private var headroomReason: LocalizedStringResource? {
        guard let utilisation = snapshot.adapterUtilisation, utilisation < 0.75 else { return nil }
        if monitor.thermal.state.isThrottling {
            return "Well under the adapter's rating while the system is thermally throttling — the ceiling right now is heat, not the charger."
        }
        if snapshot.isChargingOnHold {
            return "Charging is on hold, so almost nothing is being drawn. Optimized Battery Charging or a charge limit looks exactly like this."
        }
        if let percent = snapshot.percent, percent > 80 {
            return "Above 80% the charger tapers to constant-voltage, so low draw here is normal battery chemistry, not a weak charger."
        }
        if snapshot.isWirelessInput {
            return "Wireless charging is capped well below what the adapter could deliver over the cable."
        }
        return "The phone-reported input is below the adapter's rating. This alone cannot tell whether the difference is a charging limit or a sensor-path mismatch."
    }

    // MARK: Identity

    private var identityPanel: some View {
        Panel("Handshake", systemImage: "person.text.rectangle") {
            VStack(spacing: 0) {
                DetailRow(label: "Name", value: snapshot.adapterName)
                DetailRow(label: "Manufacturer", value: snapshot.adapterManufacturer)
                DetailRow(label: "Model", value: snapshot.adapterModel)
                DetailRow(label: "Serial", value: snapshot.adapterSerial)
                DetailRow(label: "Source", value: snapshot.adapterSource)
                DetailRow(label: "Power tier", value: snapshot.adapterPowerTier.map(String.init))
                DetailRow(label: "Negotiated max", value: snapshot.negotiatedProfile?.label)
                DetailRow(label: "Transport", value: DetailRow.transportName(wireless: snapshot.adapterIsWireless))
            }
        }
    }

    // MARK: Profiles

    private var profilesPanel: some View {
        Panel("Advertised profiles", systemImage: "list.bullet.rectangle",
              trailing: snapshot.adapterProfiles.isEmpty ? nil : Text(verbatim: "\(snapshot.adapterProfiles.count)")) {
            if snapshot.adapterProfiles.isEmpty {
                EmptyNote(text: "This adapter published no PD profile menu. Legacy USB-A chargers and some wireless pads report only a single voltage and current.")
            } else {
                VStack(spacing: 8) {
                    ForEach(snapshot.adapterProfiles) { profile in
                        ProfileRow(profile: profile,
                                   isActive: profile.index == snapshot.negotiatedProfile?.index)
                    }
                }
            }
        }
    }

    // MARK: Rails

    /// The raw voltage and current sensors, grouped by which side of the charge IC
    /// they sit on. This is the ground truth behind every derived number above.
    private var railsPanel: some View {
        Panel("Live rails", systemImage: "bolt.horizontal") {
            let rails: [RailRow] = [
                RailRow(id: "usb", name: "USB-C input",
                        voltage: snapshot.usbInputVoltage, current: snapshot.usbInputCurrent, tint: .mwAccent),
                RailRow(id: "wireless", name: "Wireless input",
                        voltage: snapshot.wirelessInputVoltage, current: snapshot.wirelessInputCurrent, tint: .mwWireless),
                RailRow(id: "battery", name: "Battery rail",
                        voltage: snapshot.batteryRailVoltage, current: snapshot.batteryRailCurrent, tint: .mwBattery),
            ]
            VStack(spacing: 10) {
                ForEach(rails) { rail in
                    let (voltage, current, tint) = (rail.voltage, rail.current, rail.tint)
                    HStack {
                        Text(rail.name)
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        Text(voltage.map { String(format: "%.2f V", $0) } ?? "—")
                            .mwMono(size: 12)
                            .foregroundStyle(voltage == nil ? Color.mwMuted : .primary)
                        Text(verbatim: "×").font(.caption2).foregroundStyle(Color.mwMuted)
                        Text(current.map { String(format: "%.2f A", $0) } ?? "—")
                            .mwMono(size: 12)
                            .foregroundStyle(current == nil ? Color.mwMuted : .primary)
                        Text(watts(voltage, current).map { String(format: "%.1f W", $0) } ?? "—")
                            .mwMono(size: 12, weight: .semibold)
                            .foregroundStyle(tint)
                            .frame(width: 54, alignment: .trailing)
                    }
                }
            }
        }
    }

    private func watts(_ voltage: Double?, _ current: Double?) -> Double? {
        guard let voltage, let current else { return nil }
        return voltage * current
    }
}

/// One row of the live-rails table. A named type rather than a tuple so the label
/// can be a `LocalizedStringResource` and the row can carry its own identity.
private struct RailRow: Identifiable {
    let id: String
    let name: LocalizedStringResource
    let voltage: Double?
    let current: Double?
    let tint: Color
}

struct ProfileRow: View {
    let profile: PDProfile
    let isActive: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                .font(.system(size: 13))
                .foregroundStyle(isActive ? Color.mwAccent : Color.mwMuted.opacity(0.5))
            Text(verbatim: profile.label)
                .mwMono(size: 13, weight: isActive ? .semibold : .regular)
            Spacer()
            Text(String(format: "%.0f W", profile.watts))
                .mwReadout(size: 14, weight: .semibold)
                .foregroundStyle(isActive ? Color.mwAccent : Color.mwMuted)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isActive ? Color.mwAccent.opacity(0.12) : Color.mwMuted.opacity(0.06))
        )
    }
}

/// Label on the left, value on the right, hidden entirely when there is no value.
///
/// The label is a `Text` for the same reason `Panel.trailing` is: a detail row shows
/// copy on the Adapter page ("Manufacturer") and a raw IOKit key on the Raw data page
/// (`AppleRawAdapterDetails`), and only one of those may reach the string catalog.
/// Which it is, is knowable at the call site and nowhere else — hence two initialisers
/// rather than one `String` that silently took the non-localising `Text` overload and
/// opted every label out of translation.
struct DetailRow: View {
    private let label: Text
    /// Always a measured or reported value — a serial number, a wattage, a
    /// timestamp — so never translated.
    let value: String?

    /// A translated label.
    init(label: LocalizedStringResource, value: String?) {
        self.label = Text(label)
        self.value = value
    }

    /// A hardware name or dictionary key, shown exactly as the system reported it.
    init(rawLabel: String, value: String?) {
        self.label = Text(verbatim: rawLabel)
        self.value = value
    }

    /// The transport a charge arrived over. Copy, but it is a *value* rather than a
    /// label, so it is resolved to a `String` here. Two separate `String(localized:)`
    /// calls rather than one wrapped around a ternary: the extractor reads literals
    /// at the call site, not through a branch.
    static func transportName(wireless: Bool) -> String {
        wireless ? String(localized: "Wireless") : String(localized: "USB-C")
    }

    /// Nested IOKit dictionaries arrive as long multi-line strings; those get their
    /// own left-aligned block instead of being crushed into the right column.
    private var isLong: Bool {
        guard let value else { return false }
        return value.count > 34 || value.contains("\n")
    }

    var body: some View {
        if let value, !value.isEmpty {
            Group {
                if isLong {
                    VStack(alignment: .leading, spacing: 3) {
                        label
                            .font(.system(size: 13))
                            .foregroundStyle(Color.mwMuted)
                        Text(verbatim: value)
                            .mwMono(size: 11)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    HStack(alignment: .firstTextBaseline) {
                        label
                            .font(.system(size: 13))
                            .foregroundStyle(Color.mwMuted)
                        Spacer(minLength: 12)
                        Text(verbatim: value)
                            .mwMono(size: 12)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(.vertical, 6)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.mwCardStroke).frame(height: 0.5)
            }
        }
    }
}
