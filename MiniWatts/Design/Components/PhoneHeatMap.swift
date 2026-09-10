import SwiftUI

/// A rough thermal map of the phone: each sensor zone glows at its own colour
/// and position, so charging heat can be seen moving from the charge IC at the
/// bottom up through the battery and the SoC.
///
/// The positions are approximate by design — the sandbox gives temperatures and
/// sensor names, never coordinates — so this is a legend for the numbers below
/// it, not a claim about millimetres.
struct PhoneHeatMap: View {
    /// Hottest reading per zone.
    let readings: [(zone: ThermalZone, celsius: Double)]
    var height: CGFloat = 250

    private var width: CGFloat { height * 0.49 }

    var body: some View {
        ZStack {
            let shape = RoundedRectangle(cornerRadius: width * 0.16, style: .continuous)

            shape
                .fill(Color.mwMuted.opacity(0.08))
                .overlay(shape.strokeBorder(Color.mwCardStroke, lineWidth: 1))

            // Heat blobs, clipped to the body so the glow does not spill outside.
            ZStack {
                ForEach(readings, id: \.zone) { reading in
                    Circle()
                        .fill(
                            RadialGradient(colors: [Color.mwTemperature(reading.celsius).opacity(0.85), .clear],
                                           center: .center,
                                           startRadius: 0,
                                           endRadius: width * 0.42)
                        )
                        .frame(width: width * 0.85, height: width * 0.85)
                        .position(x: width * reading.zone.position.x,
                                  y: height * reading.zone.position.y)
                }
            }
            .frame(width: width, height: height)
            .blur(radius: 14)
            .blendMode(.plusLighter)
            .clipShape(shape)

            // Sensor pins.
            ZStack {
                ForEach(readings, id: \.zone) { reading in
                    VStack(spacing: 2) {
                        Image(systemName: reading.zone.symbol)
                            .font(.system(size: 9, weight: .bold))
                        Text(String(format: "%.0f°", reading.celsius))
                            .mwMono(size: 9, weight: .semibold)
                    }
                    .foregroundStyle(Color.mwTemperature(reading.celsius))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.mwCard.opacity(0.82)))
                    .overlay(Capsule().strokeBorder(Color.mwTemperature(reading.celsius).opacity(0.5), lineWidth: 0.5))
                    .position(x: width * reading.zone.position.x,
                              y: height * reading.zone.position.y)
                }
            }
            .frame(width: width, height: height)

            // Dynamic Island, purely so the silhouette reads as a phone.
            Capsule()
                .fill(Color.mwCanvas)
                .frame(width: width * 0.3, height: height * 0.035)
                .position(x: width / 2, y: height * 0.055)
        }
        .frame(width: width, height: height)
        .clipped()
    }
}

/// The colour key for the map.
struct TemperatureScale: View {
    var body: some View {
        HStack(spacing: 6) {
            ForEach([25.0, 31.0, 36.0, 41.0, 46.0], id: \.self) { celsius in
                HStack(spacing: 3) {
                    Circle()
                        .fill(Color.mwTemperature(celsius))
                        .frame(width: 6, height: 6)
                    Text(celsius >= 46 ? "46+" : "\(Int(celsius))")
                        .mwMono(size: 9)
                        .foregroundStyle(Color.mwMuted)
                }
            }
            Text(verbatim: "°C").mwMono(size: 9).foregroundStyle(Color.mwMuted)
        }
    }
}
