import AVFoundation
import SwiftUI

/// One frame of the floating window.
///
/// Fixed dark colours rather than the app's palette: this is rendered into a video
/// frame by `ImageRenderer` and then drawn by the system over whatever is on screen,
/// so there is no appearance to follow and no guarantee about what is behind it.
struct FloatingMeterFrame: View {
    let reading: ChargeReading

    private static let ink = Color(UIColor(hex: 0xF2F5FA))
    private static let muted = Color(UIColor(hex: 0x8C93A6))
    private static let accent = Color(UIColor(hex: 0x35DFFF))
    private static let battery = Color(UIColor(hex: 0x3FE08C))
    private static let wireless = Color(UIColor(hex: 0xB49BFF))
    private static let top = Color(UIColor(hex: 0x0F1520))
    private static let bottom = Color(UIColor(hex: 0x06070A))

    private var tint: Color {
        switch reading.source {
        case .charger: return Self.accent
        case .magSafe: return Self.wireless
        case .intoBattery: return Self.battery
        case .fromBattery, .none: return Self.muted
        }
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Self.top, Self.bottom],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(alignment: .leading, spacing: 0) {
                header
                Spacer(minLength: 0)
                watts
                Spacer(minLength: 0)
                footer
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: reading.symbolName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
            Text(reading.statusTitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Self.ink)
            Spacer(minLength: 8)
            // The clock is what makes a frozen window obvious: if the seconds stop,
            // the reading behind them stopped too.
            Text(verbatim: Formatting.clock(reading.date))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(Self.muted)
        }
    }

    private var watts: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: reading.watts.map(Formatting.watts) ?? "—")
                .font(.system(size: 58, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Self.ink)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: "W")
                    .font(.system(size: 19, weight: .medium, design: .rounded))
                    .foregroundStyle(Self.muted)
            }
            Spacer(minLength: 0)
            if let source = reading.source {
                Text(source.caption)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(tint)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 7) {
            LevelStripe(percent: reading.percent, tint: tint)
            HStack(spacing: 8) {
                Text(verbatim: reading.percentText)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Self.ink)
                Spacer(minLength: 0)
                if let temperature = reading.batteryTemperature {
                    Text(verbatim: Formatting.temperature(temperature))
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(Self.muted)
                }
            }
        }
    }
}

/// The widget's `LevelBar`, again — that one is compiled into the extension only,
/// and a five-line capsule is not worth a third file in both targets.
private struct LevelStripe: View {
    let percent: Int?
    let tint: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.14))
                Capsule()
                    .fill(tint)
                    .frame(width: max(5, geometry.size.width * CGFloat(min(max(Double(percent ?? 0) / 100, 0), 1))))
            }
        }
        .frame(height: 5)
    }
}

/// Holds the layer Picture in Picture draws from.
///
/// It has to be in the window hierarchy — the system will not open a window for a
/// layer that is not on screen — and it has to stay there, because PiP stops when
/// its source goes away. `RootView` keeps it behind the tab bar at a few points
/// across; the frames people actually look at are the ones in the PiP window.
struct FloatingMeterStage: UIViewRepresentable {
    let controller: FloatingMeterController

    func makeUIView(context: Context) -> UIView {
        let host = LayerHost()
        host.isUserInteractionEnabled = false
        host.layer.addSublayer(controller.layer)
        return host
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    final class LayerHost: UIView {
        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.sublayers?.forEach { $0.frame = bounds }
            CATransaction.commit()
        }
    }
}
