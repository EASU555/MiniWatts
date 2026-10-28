import SwiftUI

/// Shared wording for a partial sensor path, never a calibrated charger reading.
struct InputPowerWarning: View {
    let snapshot: PowerSnapshot

    var body: some View {
        if let partial = snapshot.partialInputWatts, snapshot.externalConnected {
            VStack(alignment: .leading, spacing: 8) {
                Label("Incomplete input reading", systemImage: "exclamationmark.triangle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.mwLoss)
                Text("The input sensors account for less power than reaches the cell. The main reading uses battery-side power; complete input power is unavailable, not estimated or doubled.")
                    .font(.caption)
                    .foregroundStyle(Color.mwMuted)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text("Partial input sensor product")
                    Spacer(minLength: 8)
                    Text(verbatim: String(format: "%.1f W", partial))
                        .monospacedDigit()
                }
                .font(.caption2)
                .foregroundStyle(Color.mwMuted)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

struct HighPowerCaution: View {
    @Environment(PowerMonitor.self) private var monitor

    var body: some View {
        if monitor.mayReadHalfInput || monitor.levelRateCheck != nil {
            VStack(alignment: .leading, spacing: 8) {
                if monitor.mayReadHalfInput {
                    Label("High-power reading may be incomplete", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Color.mwLoss)
                    Text("On iPhone 18 Pro, both input and battery sensors can read low during high-power wired charging. The complete power is unknown and is not automatically doubled.")
                }
                if let check = monitor.levelRateCheck {
                    if check.isLow { Text("Level comparison suggests the cell reading may be low.") }
                    else if check.agrees { Text("Level comparison is consistent with the cell reading.") }
                    else { Text("Level comparison is inconclusive.") }
                    HStack {
                        Text("Level estimate / cell reading")
                        Spacer()
                        Text(verbatim: String(format: "%.1f / %.1f W", check.levelWatts, check.cellWatts))
                            .monospacedDigit()
                    }
                    Text("This comparison is experimental, takes several minutes and depends on the configured battery energy. It is not a real-time power measurement.")
                }
            }
            .font(.caption).foregroundStyle(Color.mwMuted)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
        }
    }
}
