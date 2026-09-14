import AVFoundation
import SwiftUI
import UIKit

struct TelemetryPictureInPicturePreview: UIViewRepresentable {
    let controller: TelemetryPictureInPictureController

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    func makeUIView(context: Context) -> TelemetryPictureInPictureSourceView {
        let view = TelemetryPictureInPictureSourceView()
        controller.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: TelemetryPictureInPictureSourceView, context: Context) {
        controller.attach(to: uiView)
        controller.layoutSource(in: uiView.bounds)
    }

    static func dismantleUIView(
        _ uiView: TelemetryPictureInPictureSourceView,
        coordinator: Coordinator
    ) {
        coordinator.controller.detach(from: uiView)
    }

    final class Coordinator {
        let controller: TelemetryPictureInPictureController

        init(controller: TelemetryPictureInPictureController) {
            self.controller = controller
        }
    }
}

final class TelemetryPictureInPictureSourceView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

struct TelemetryVideoFrameView: View {
    let data: TelemetryFrameData?
    let showPower: Bool
    let showTemperatures: Bool
    let layout: TelemetryPictureInPictureLayout

    private var displaysPowerPage: Bool {
        guard showPower else { return false }
        guard showTemperatures, layout == .separatePages, let data else { return true }
        return Int(data.date.timeIntervalSinceReferenceDate / 4).isMultiple(of: 2)
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.035, green: 0.055, blue: 0.09), .black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(spacing: 16) {
                header
                if !showPower && !showTemperatures {
                    noSelection
                } else if layout == .separatePages && showPower && showTemperatures {
                    if displaysPowerPage { powerPage } else { temperaturePage }
                } else if showPower && showTemperatures {
                    togetherPage
                } else if showPower {
                    powerPage
                } else {
                    temperaturePage
                }
                footer
            }
            .padding(24)
        }
        .foregroundStyle(.white)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: data?.isWireless == true
                  ? "bolt.horizontal.circle.fill" : "bolt.circle.fill")
                .foregroundStyle(.cyan)
            Text("MINIWATTS")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .tracking(1.8)
            Spacer()
            if let percent = data?.batteryPercent {
                Label {
                    Text(verbatim: "\(percent)%")
                } icon: {
                    Image(systemName: "battery.75percent")
                }
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(.green)
            }
        }
    }

    private var footer: some View {
        HStack {
            Circle()
                .fill(data == nil ? Color.secondary : Color.green)
                .frame(width: 8, height: 8)
            Text(verbatim: data == nil ? "WAITING" : "LIVE · 1S")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
            if let date = data?.date {
                Text(date, format: .dateTime.hour().minute().second())
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var noSelection: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.slash")
                .font(.system(size: 40, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Select content in Settings")
                .font(.system(size: 24, weight: .semibold, design: .rounded))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var togetherPage: some View {
        HStack(spacing: 16) {
            powerReadout(compact: true)
                .frame(maxWidth: 220)
            temperatureGrid
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var powerPage: some View {
        powerReadout(compact: false)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func powerReadout(compact: Bool) -> some View {
        VStack(alignment: compact ? .leading : .center, spacing: 8) {
            Label("Charging power", systemImage: "bolt.fill")
                .font(.system(size: compact ? 17 : 21,
                              weight: .semibold,
                              design: .rounded))
                .foregroundStyle(.cyan)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: formatted(data?.chargeWatts))
                    .font(.system(size: compact ? 62 : 94,
                                  weight: .bold,
                                  design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.7)
                Text(verbatim: "W")
                    .font(.system(size: compact ? 22 : 30,
                                  weight: .semibold,
                                  design: .rounded))
                    .foregroundStyle(.secondary)
            }
            Text(powerSourceText)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var temperaturePage: some View {
        VStack(spacing: 12) {
            Label("Component temperatures", systemImage: "thermometer.medium")
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .foregroundStyle(.orange)
            temperatureGrid
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var temperatureGrid: some View {
        HStack(spacing: 8) {
            temperatureCell("SoC", value: data?.socTemperature, symbol: "cpu")
            temperatureCell("Battery", value: data?.batteryTemperature,
                            symbol: "battery.75percent")
            temperatureCell("Charger", value: data?.chargerTemperature,
                            symbol: "powerplug.fill")
            temperatureCell("Hottest", value: data?.hottestTemperature,
                            symbol: "thermometer.high",
                            detail: data?.hottestSensorName)
        }
    }

    private func temperatureCell(
        _ title: LocalizedStringKey,
        value: Double?,
        symbol: String,
        detail: String? = nil
    ) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(temperatureColor(value))
            Text(title)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(verbatim: formatted(value))
                    .font(.system(size: 29, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(verbatim: "°")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            Text(verbatim: detail ?? " ")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        }
    }

    private var powerSourceText: LocalizedStringKey {
        guard data?.externalConnected == true else { return "Not charging" }
        if data?.powerIsBatterySide == true { return "Into battery" }
        return data?.isWireless == true ? "From wireless charger" : "From charger"
    }

    private func formatted(_ value: Double?) -> String {
        value?.formatted(.number.precision(.fractionLength(1))) ?? "—"
    }

    private func temperatureColor(_ value: Double?) -> Color {
        guard let value else { return .secondary }
        switch value {
        case ..<34: return .green
        case ..<39: return .yellow
        case ..<44: return .orange
        default: return .red
        }
    }
}
