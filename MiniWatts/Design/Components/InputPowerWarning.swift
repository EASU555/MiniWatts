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
