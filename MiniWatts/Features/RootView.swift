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
            ProblemReportRecorder.shared.record("coexistence", "scene=\(phase) \(coexistenceEvidence)")
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
            ProblemReportRecorder.shared.record("coexistence", "backgroundSampling=\(keepSampling) \(coexistenceEvidence)")
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
        .onChange(of: monitor.liveActivityRecoveryStatus) { _, status in
            ProblemReportRecorder.shared.record("coexistence", "activity=\(status) \(coexistenceEvidence)")
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            ProblemReportRecorder.shared.record("lifecycle", "memory warning received")
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)) { _ in
            ProblemReportRecorder.shared.record("lifecycle", "termination notification received (best effort)")
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

    /// A single event ties the three independently owned lifecycles together.
    /// AVKit and ActivityKit may each report success while the sample loop is
    /// paused, so a PiP-only or activity-only log cannot diagnose coexistence.
    private var coexistenceEvidence: String {
        "pip=[\(pictureInPicture.diagnosticSummary)] "
            + "activity=\(monitor.liveActivityRecoveryStatus) "
            + "activityEnabled=\(monitor.liveActivityEnabled) "
            + "sampleAge=\(String(format: "%.1f", Date.now.timeIntervalSince(monitor.snapshot.date)))s"
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
        Text(verbatim: "v\(Self.version) · B\(Self.build)")
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
    var onScrollingChanged: ((Bool) -> Void)?
    @ViewBuilder var content: () -> Content

    init(_ title: LocalizedStringResource,
         glow: Color = .mwAccent,
         toolbar: AnyView? = nil,
         onScrollingChanged: ((Bool) -> Void)? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.glow = glow
        self.toolbar = toolbar
        self.onScrollingChanged = onScrollingChanged
        self.content = content
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Backdrop(glow: glow)
                scrollView
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

    @ViewBuilder private var scrollView: some View {
        if #available(iOS 18.0, *), onScrollingChanged != nil {
            scrollContent.onScrollPhaseChange { _, phase in
                onScrollingChanged?(phase.isScrolling)
            }
        } else {
            scrollContent
        }
    }

    private var scrollContent: some View {
        ScrollView {
            // History can hold sixty session panels. Keep layout lazy so only
            // visible rows are measured during the one-second sensor tick.
            LazyVStack(spacing: 14) {
                content()
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 24)
            // Clamp long labels to the page width instead of widening the scroll.
            .containerRelativeFrame(.horizontal)
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
