import SwiftUI
import UIKit

struct RootView: View {
    @Environment(PowerMonitor.self) private var monitor
    @Environment(TelemetryPictureInPictureController.self) private var pictureInPicture
    @Environment(\.scenePhase) private var scenePhase
    @State private var widgetPublisher = WidgetPublisher()

    var body: some View {
        TabView {
            DashboardView()
                .tabItem { Label("Power", systemImage: "bolt.fill") }
            ThermalView()
                .tabItem { Label("Thermal", systemImage: "thermometer.medium") }
            AdapterView()
                .tabItem { Label("Adapter", systemImage: "powerplug.fill") }
            DevicesView()
                .tabItem { Label("Devices", systemImage: "square.stack.3d.up.fill") }
            SessionsView()
                .tabItem { Label("History", systemImage: "chart.xyaxis.line") }
        }
        .tint(.mwAccent)
        .background(alignment: .topLeading) {
            // AVKit requires its presenting sample-buffer layer to remain in the
            // window hierarchy. Hosting it here avoids Settings redraws moving or
            // destroying the active PiP source.
            TelemetryPictureInPicturePreview(controller: pictureInPicture)
                .frame(width: 16, height: 9)
                .opacity(0.02)
                .allowsHitTesting(false)
        }
        .task {
            pictureInPicture.backgroundPulse = { [weak monitor] in
                monitor?.refreshIfDue()
            }
            monitor.onTick = { [weak monitor, pictureInPicture, widgetPublisher] snapshot in
                guard let monitor else { return }
                pictureInPicture.update(
                    snapshot: snapshot,
                    thermalState: monitor.thermal.state
                )
                widgetPublisher.publish(
                    ChargeReading(snapshot),
                    lastSession: monitor.sessions.first
                )
            }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .active:
                pictureInPicture.recoverAfterEnteringForeground()
                monitor.start()
                monitor.recoverLiveActivityAfterEnteringForeground()
            case .background:
                widgetPublisher.flush(
                    ChargeReading(monitor.snapshot),
                    lastSession: monitor.sessions.first
                )
                // PiP is the one user-visible background-sampling mode. A Live
                // Activity alone doesn't grant the app continuous execution time.
                if !keepsBackgroundSamplingActive {
                    monitor.pause()
                }
            default:
                // `.inactive` is transient and the app is still on screen for most
                // of it: a pulled-down Control Center, the app switcher, an
                // incoming call. Nothing to do.
                break
            }
        }
        .onChange(of: keepsBackgroundSamplingActive) { _, keepSampling in
            guard scenePhase == .background else { return }
            if keepSampling {
                monitor.start()
            } else {
                monitor.pause()
            }
        }
        .onChange(of: shouldStayAwake, initial: true) { _, awake in
            UIApplication.shared.isIdleTimerDisabled = awake
        }
    }

    /// Hold the screen on, but only while it is actually earning something: the app
    /// is in front and the phone is plugged in. Keeping a battery instrument awake
    /// on battery would be a poor joke.
    private var shouldStayAwake: Bool {
        monitor.keepScreenAwakeWhileCharging
            && monitor.snapshot.externalConnected
            && scenePhase == .active
    }

    private var keepsBackgroundSamplingActive: Bool {
        pictureInPicture.keepsSensorSamplingActive
    }
}

/// Always-visible release identifier so screenshots can be matched to the
/// exact sideloaded version.
struct AppVersionBadge: View {
    private static let version = Bundle.main.object(
        forInfoDictionaryKey: "CFBundleShortVersionString"
    ) as? String ?? "—"

    private static let build = Bundle.main.object(
        forInfoDictionaryKey: "CFBundleVersion"
    ) as? String ?? "—"

    var body: some View {
        Text(verbatim: "v\(Self.version)")
            .font(.caption2.monospaced().weight(.bold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: true)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.mwAccent, in: Capsule())
            .accessibilityLabel("Version \(Self.version), build \(Self.build)")
    }
}

/// Shared page chrome: the instrument backdrop behind a scrolling column of panels.
struct PageScaffold<Content: View>: View {
    let title: LocalizedStringResource
    var glow: Color = .mwAccent
    var toolbar: AnyView?
    @ViewBuilder var content: () -> Content

    init(_ title: LocalizedStringResource,
         glow: Color = .mwAccent,
         toolbar: AnyView? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.glow = glow
        self.toolbar = toolbar
        self.content = content
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Backdrop(glow: glow)
                ScrollView {
                    // Lazy, not a plain `VStack`. History puts up to sixty session
                    // panels in here, each with its own sparkline, and an eager stack
                    // builds and measures every one of them — while charging, once a
                    // second, because the page reads the live session.
                    LazyVStack(spacing: 14) {
                        content()
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 24)
                    // Pinned to the container's width so nothing inside can widen the
                    // scroll content. A paragraph inside an HStack reports an enormous
                    // ideal width — the text unwrapped onto one line — and
                    // `.frame(maxWidth: .infinity)` only expands, it does not clamp, so
                    // that width propagates up and the page starts scrolling sideways.
                    .containerRelativeFrame(.horizontal)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    AppVersionBadge()
                        .allowsHitTesting(false)
                }
                if let toolbar {
                    ToolbarItem(placement: .topBarTrailing) { toolbar }
                }
            }
        }
    }
}

/// Used wherever a probe legitimately has nothing to report.
struct EmptyNote: View {
    let text: LocalizedStringResource
    var systemImage: String = "info.circle"

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.mwMuted)
            Text(text)
                .font(.footnote)
                .foregroundStyle(Color.mwMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
