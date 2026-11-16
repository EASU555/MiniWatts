import SwiftUI

/// A rough thermal map of the device: each sensor zone glows at its own colour
/// and position, so charging heat can be seen moving from the charge IC at the
/// bottom up through the battery and the SoC.
///
/// The positions are approximate by design — the sandbox gives temperatures and
/// sensor names, never coordinates — so this is a legend for the numbers below
/// it, not a claim about millimetres.
struct PhoneHeatMap: View {
    /// Representative battery temperature, hottest live reading for other zones.
    let readings: [(zone: ThermalZone, celsius: Double)]
    var isTablet = false
    var height: CGFloat = 250

    private var width: CGFloat { height * (isTablet ? 0.71 : 0.49) }
    private var cornerRadius: CGFloat { width * (isTablet ? 0.075 : 0.16) }
    private var glowDiameter: CGFloat { width * (isTablet ? 0.6 : 0.85) }
    private func position(for zone: ThermalZone) -> CGPoint {
        isTablet ? zone.tabletPosition : zone.position
    }

    var body: some View {
        ZStack {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

            shape
                .fill(Color.mwMuted.opacity(0.08))
                .overlay(shape.strokeBorder(Color.mwCardStroke, lineWidth: 1))

            if isTablet {
                RoundedRectangle(cornerRadius: cornerRadius * 0.6, style: .continuous)
                    .strokeBorder(Color.mwCardStroke.opacity(0.8), lineWidth: 0.5)
                    .padding(width * 0.045)
            }

            // Heat blobs, clipped to the body so the glow does not spill outside.
            ZStack {
                ForEach(readings, id: \.zone) { reading in
                    let primary = position(for: reading.zone)
                    let points = isTablet && reading.zone == .battery
                        ? [primary, CGPoint(x: 1 - primary.x, y: primary.y)] : [primary]
                    ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                        Circle()
                            .fill(
                                RadialGradient(colors: [Color.mwTemperature(reading.celsius).opacity(0.85), .clear],
                                               center: .center,
                                               startRadius: 0,
                                               endRadius: glowDiameter / 2)
                            )
                            .frame(width: glowDiameter, height: glowDiameter)
                            .position(x: width * point.x, y: height * point.y)
                    }
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
                        Image(systemName: isTablet && reading.zone == .surface ? "ipad" : reading.zone.symbol)
                            .font(.system(size: 9, weight: .bold))
                        Text(String(format: "%.0f°", reading.celsius))
                            .mwMono(size: 9, weight: .semibold)
                    }
                    .foregroundStyle(Color.mwTemperature(reading.celsius))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.mwCard.opacity(0.82)))
                    .overlay(Capsule().strokeBorder(Color.mwTemperature(reading.celsius).opacity(0.5), lineWidth: 0.5))
                    .position(x: width * position(for: reading.zone).x,
                              y: height * position(for: reading.zone).y)
                }
            }
            .frame(width: width, height: height)

            if isTablet {
                Circle()
                    .fill(Color.mwMuted.opacity(0.45))
                    .frame(width: 4, height: 4)
                    .position(x: width / 2, y: width * 0.0225)
            } else {
                Capsule()
                    .fill(Color.mwCanvas)
                    .frame(width: width * 0.3, height: height * 0.035)
                    .position(x: width / 2, y: height * 0.055)
            }
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
