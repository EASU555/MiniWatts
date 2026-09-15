import AVFoundation
import AVKit
import Observation
import SwiftUI
import UIKit

nonisolated enum TelemetryPictureInPictureLayout: String, CaseIterable, Identifiable {
    case together
    case separatePages

    var id: Self { self }
}

nonisolated enum TelemetryTemperatureSelection: String, CaseIterable, Identifiable {
    case all
    case soc
    case battery
    case charger
    case hottest

    var id: Self { self }
}

nonisolated enum TelemetrySystemThermalState: Int, Hashable {
    case nominal
    case fair
    case serious
    case critical

    init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .nominal
        }
    }
}

nonisolated struct TelemetryFrameData: Hashable {
    let date: Date
    let externalConnected: Bool
    let isWireless: Bool
    let chargeWatts: Double?
    let powerIsBatterySide: Bool
    let batteryPercent: Int?
    let socTemperature: Double?
    let batteryTemperature: Double?
    let chargerTemperature: Double?
    let hottestTemperature: Double?
    let hottestSensorName: String?
    let systemThermalState: TelemetrySystemThermalState

    init(snapshot: PowerSnapshot, thermalState: ProcessInfo.ThermalState) {
        let power = snapshot.chargingPower
        date = snapshot.date
        externalConnected = snapshot.externalConnected
        isWireless = snapshot.isWirelessInput
        chargeWatts = power.watts
        powerIsBatterySide = power.isBatterySide
        batteryPercent = snapshot.percent
        socTemperature = snapshot.socTemperature
        batteryTemperature = snapshot.batteryTemperature
        chargerTemperature = snapshot.chargerTemperature
        hottestTemperature = snapshot.hottestSensor?.value
        hottestSensorName = snapshot.hottestSensor?.name
        systemThermalState = TelemetrySystemThermalState(thermalState)
    }
}

/// Turns telemetry into a one-frame-per-second video stream and hands that stream to
/// the system Picture in Picture controller. PiP is user initiated; while it remains
/// active, RootView keeps PowerMonitor's sensor tick alive in the background.
@Observable
@MainActor
final class TelemetryPictureInPictureController: NSObject {
    private static let showPowerKey = "pictureInPictureShowPower"
    private static let showTemperaturesKey = "pictureInPictureShowTemperatures"
    private static let layoutKey = "pictureInPictureLayout"
    private static let temperatureSelectionKey = "pictureInPictureTemperatureSelection"
    private static let autoHideWhenDockedKey = "pictureInPictureAutoHideWhenDocked"
    private static let frameSize = CGSize(width: 640, height: 360)
    /// The video-call content-source route accepts a fractional height. At 0.1 pt
    /// the active PiP session remains alive, while its docked system tab has no
    /// visible surface left to draw.
    private static let hiddenFrameSize = CGSize(width: 640, height: 0.1)

    var showPower: Bool {
        didSet {
            UserDefaults.standard.set(showPower, forKey: Self.showPowerKey)
            renderLatest()
        }
    }

    var showTemperatures: Bool {
        didSet {
            UserDefaults.standard.set(showTemperatures, forKey: Self.showTemperaturesKey)
            renderLatest()
        }
    }

    var layout: TelemetryPictureInPictureLayout {
        didSet {
            UserDefaults.standard.set(layout.rawValue, forKey: Self.layoutKey)
            renderLatest()
        }
    }

    var temperatureSelection: TelemetryTemperatureSelection {
        didSet {
            UserDefaults.standard.set(
                temperatureSelection.rawValue,
                forKey: Self.temperatureSelectionKey
            )
            renderLatest()
        }
    }

    var autoHideWhenDocked: Bool {
        didSet {
            UserDefaults.standard.set(autoHideWhenDocked, forKey: Self.autoHideWhenDockedKey)
            if autoHideWhenDocked {
                scheduleAutomaticHide()
            } else {
                restoreVisiblePresentation()
            }
        }
    }

    private(set) var isActive = false
    private(set) var isStarting = false
    private(set) var isPossible = false
    private(set) var isVisuallyHidden = false
    private(set) var errorMessage: LocalizedStringResource?

    @ObservationIgnored private var pictureInPictureController: AVPictureInPictureController?
    @ObservationIgnored private var pictureInPicturePossibleObservation: NSKeyValueObservation?
    @ObservationIgnored private var pictureInPictureSuspendedObservation: NSKeyValueObservation?
    @ObservationIgnored private var videoCallContentController: AVPictureInPictureVideoCallViewController?
    @ObservationIgnored private weak var videoCallImageView: UIImageView?
    /// AVKit does not guarantee a terminal delegate callback when a start request is
    /// interrupted by an audio-session or scene transition. Keep one bounded attempt
    /// so Settings can never remain stuck in its loading state.
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var startAttempt = 0
    @ObservationIgnored private var autoHideTask: Task<Void, Never>?
    /// PowerMonitor installs these hooks from RootView so ActivityKit owns the
    /// shared background-audio session before AVKit starts, then gets another
    /// forced reconciliation after each PiP presentation transition.
    @ObservationIgnored var prepareLiveActivityForStart: (() -> Bool)?
    @ObservationIgnored var recoverLiveActivityAfterTransition: (() -> Void)?
    // Kept strongly while PiP is active so SwiftUI dismantling its representable
    // cannot also destroy the video-call source AVKit is still presenting.
    @ObservationIgnored private var sourceView: UIView?
    /// SwiftUI may replace the inline preview while a settings value changes.
    /// Moving the active video-call source to that replacement interrupts the
    /// content source AVKit is presenting and can leave the PiP window black.
    /// Remember the new host and reattach only after PiP has stopped.
    @ObservationIgnored private weak var pendingSourceView: UIView?
    @ObservationIgnored private var sourceViewWasDismantled = false
    private(set) var latestData: TelemetryFrameData?

    override init() {
        let defaults = UserDefaults.standard
        showPower = defaults.object(forKey: Self.showPowerKey) as? Bool ?? true
        showTemperatures = defaults.object(forKey: Self.showTemperaturesKey) as? Bool ?? true
        layout = defaults.string(forKey: Self.layoutKey)
            .flatMap(TelemetryPictureInPictureLayout.init(rawValue:)) ?? .together
        temperatureSelection = defaults.string(forKey: Self.temperatureSelectionKey)
            .flatMap(TelemetryTemperatureSelection.init(rawValue:)) ?? .all
        autoHideWhenDocked = defaults.object(forKey: Self.autoHideWhenDockedKey) as? Bool ?? true
        super.init()
    }

    var isSupported: Bool {
        AVPictureInPictureController.isPictureInPictureSupported()
    }

    var hasSelectedContent: Bool { showPower || showTemperatures }
    var keepsSensorSamplingActive: Bool { isActive || isStarting }

    func attach(to view: UIView) {
        if keepsSensorSamplingActive, sourceView !== view {
            pendingSourceView = view
            return
        }

        let needsAttachment = sourceView !== view
        if needsAttachment {
            // Unlike the old sample-buffer route, a video-call ContentSource owns
            // the exact UIView passed at construction time. Rebuild whenever
            // SwiftUI replaces that inactive host so AVKit never points at a
            // dismantled view.
            discardPictureInPictureController()
        }
        sourceView = view
        pendingSourceView = nil
        sourceViewWasDismantled = false
        ensurePictureInPictureController()
        if needsAttachment {
            renderLatest()
        }
    }

    func layoutSource(in bounds: CGRect, hostedBy view: UIView) {
        guard sourceView === view else { return }
    }

    func detach(from view: UIView) {
        if pendingSourceView === view {
            pendingSourceView = nil
        }
        guard sourceView === view else { return }
        if keepsSensorSamplingActive {
            sourceViewWasDismantled = true
            return
        }
        discardPictureInPictureController()
        sourceView = nil
        sourceViewWasDismantled = false
        isPossible = false
    }

    func update(snapshot: PowerSnapshot, thermalState: ProcessInfo.ThermalState) {
        latestData = TelemetryFrameData(snapshot: snapshot, thermalState: thermalState)
        guard sourceView != nil || keepsSensorSamplingActive else { return }
        renderLatest()
    }

    func start() {
        guard isSupported, hasSelectedContent, !keepsSensorSamplingActive else { return }
        errorMessage = nil

        // Starting the video-call PiP content source can rebuild the shared audio
        // graph. If the Live Activity keeper is already running, reapplying the
        // category here can stop that graph and strand ActivityKit on stale data.
        // Let PowerMonitor establish ownership first and only configure the session
        // ourselves when there is no active Live Activity keeper.
        let liveActivityOwnsAudioSession = prepareLiveActivityForStart?() ?? false
        if !liveActivityOwnsAudioSession {
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
                try session.setActive(true)
            } catch {
                errorMessage = "Picture in Picture audio mode could not start."
                return
            }
        }

        guard let sourceView, sourceView.window != nil else {
            errorMessage = "Picture in Picture is not ready. Keep the preview visible and try again."
            return
        }

        // Prefer the controller that is already attached to the stable RootView
        // source. Replacing it on every tap creates a race with AVKit readiness.
        sourceView.layoutIfNeeded()
        restoreVisiblePresentation()
        renderLatest()
        ensurePictureInPictureController()
        refreshPossibleState()
        if pictureInPictureController == nil {
            rebuildRenderingPipeline()
            renderLatest()
            ensurePictureInPictureController()
        }

        isStarting = true
        startAttempt &+= 1
        let attempt = startAttempt
        startTask?.cancel()
        startTask = Task { @MainActor [weak self] in
            await self?.performStart(attempt: attempt, canRepairReadiness: true)
        }
    }

    func stop() {
        invalidateStartAttempt()
        isStarting = false
        pictureInPictureController?.stopPictureInPicture()
    }

    /// Scene suspension can pause the watchdog along with the rest of the process.
    /// Reconcile AVKit's authoritative state as soon as the app becomes active so a
    /// half-finished transition never requires a force quit.
    func recoverAfterEnteringForeground() {
        if isStarting {
            if pictureInPictureController?.isPictureInPictureActive == true {
                completeStartAttempt(startAttempt)
            } else {
                failStartAttempt(startAttempt, message: "Picture in Picture could not start.")
            }
            return
        }

        if isActive, pictureInPictureController?.isPictureInPictureActive != true {
            isActive = false
            discardPictureInPictureController()
            renderLatest()
            ensurePictureInPictureController()
            attachToPendingPreviewIfNeeded()
        }
    }

    private func performStart(attempt: Int, canRepairReadiness: Bool) async {
        // AVKit needs a committed, displayed frame before PiP becomes possible.
        // KVO normally updates the state immediately; the bounded poll also covers
        // devices that deliver the initial observation late.
        for _ in 0..<40 {
            guard isCurrentStartAttempt(attempt) else { return }
            refreshPossibleState()
            if isPossible { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard isCurrentStartAttempt(attempt) else { return }
        guard let controller = pictureInPictureController,
              controller.isPictureInPicturePossible else {
            if canRepairReadiness {
                // A controller created during SwiftUI's early view construction can
                // remain permanently impossible even though the source is now in the
                // window. Replace that one controller and retry inside the same tap.
                rebuildRenderingPipeline()
                renderLatest()
                ensurePictureInPictureController()
                await performStart(attempt: attempt, canRepairReadiness: false)
                return
            }
            failStartAttempt(
                attempt,
                message: "Picture in Picture is not ready. Keep the preview visible and try again."
            )
            return
        }

        controller.startPictureInPicture()

        // Some iOS builds occasionally deliver neither didStart nor failedToStart
        // after accepting the request. Bound that transition and discard the wedged
        // controller so the next tap works without force-quitting MiniWatts.
        for _ in 0..<50 {
            guard isCurrentStartAttempt(attempt) else { return }
            if controller.isPictureInPictureActive {
                completeStartAttempt(attempt)
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        failStartAttempt(attempt, message: "Picture in Picture could not start.")
    }

    private func isCurrentStartAttempt(_ attempt: Int) -> Bool {
        !Task.isCancelled && isStarting && startAttempt == attempt
    }

    private func completeStartAttempt(_ attempt: Int) {
        guard startAttempt == attempt else { return }
        invalidateStartAttempt()
        isStarting = false
        isActive = true
        errorMessage = nil
        scheduleAutomaticHide()
        recoverLiveActivityAfterTransition?()
    }

    private func failStartAttempt(_ attempt: Int, message: LocalizedStringResource) {
        guard startAttempt == attempt else { return }
        invalidateStartAttempt()
        isStarting = false
        isActive = false
        errorMessage = message
        discardPictureInPictureController()
        renderLatest()
        ensurePictureInPictureController()
        attachToPendingPreviewIfNeeded()
    }

    private func invalidateStartAttempt() {
        startAttempt &+= 1
        startTask?.cancel()
        startTask = nil
    }

    private func ensurePictureInPictureController() {
        guard pictureInPictureController == nil,
              isSupported,
              let sourceView else { return }

        let contentController = AVPictureInPictureVideoCallViewController()
        contentController.preferredContentSize = Self.frameSize
        contentController.view.backgroundColor = .black
        contentController.view.isOpaque = true
        contentController.view.clipsToBounds = true

        let imageView = UIImageView(frame: contentController.view.bounds)
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .black
        imageView.isOpaque = true
        contentController.view.addSubview(imageView)

        let source = AVPictureInPictureController.ContentSource(
            activeVideoCallSourceView: sourceView,
            contentViewController: contentController
        )
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        controller.requiresLinearPlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = false
        videoCallContentController = contentController
        videoCallImageView = imageView
        pictureInPictureController = controller
        let controllerID = ObjectIdentifier(controller)
        pictureInPicturePossibleObservation = controller.observe(
            \.isPictureInPicturePossible,
            options: [.initial, .new]
        ) { [weak self] _, change in
            let possible = change.newValue ?? false
            Task { @MainActor [weak self] in
                guard let self,
                      let current = self.pictureInPictureController,
                      ObjectIdentifier(current) == controllerID else { return }
                self.isPossible = possible
            }
        }
        pictureInPictureSuspendedObservation = controller.observe(
            \.isPictureInPictureSuspended,
            options: [.new]
        ) { [weak self] _, change in
            guard change.newValue == true else { return }
            Task { @MainActor [weak self] in
                guard let self,
                      let current = self.pictureInPictureController,
                      ObjectIdentifier(current) == controllerID else { return }
                self.scheduleAutomaticHide(delay: .milliseconds(350))
            }
        }
        renderLatest()
    }

    private func rebuildRenderingPipeline() {
        discardPictureInPictureController()
        ensurePictureInPictureController()
    }

    private func discardPictureInPictureController() {
        autoHideTask?.cancel()
        autoHideTask = nil
        pictureInPicturePossibleObservation = nil
        pictureInPictureSuspendedObservation = nil
        pictureInPictureController?.delegate = nil
        pictureInPictureController = nil
        videoCallImageView = nil
        videoCallContentController = nil
        isVisuallyHidden = false
        isPossible = false
    }

    private func attachToPendingPreviewIfNeeded() {
        guard !keepsSensorSamplingActive else { return }
        if let pendingSourceView, sourceView !== pendingSourceView {
            self.pendingSourceView = nil
            sourceView = pendingSourceView
            sourceViewWasDismantled = false
            rebuildRenderingPipeline()
            renderLatest()
        } else if sourceViewWasDismantled {
            self.pendingSourceView = nil
            sourceViewWasDismantled = false
            sourceView = nil
            isPossible = false
        }
    }

    private func scheduleAutomaticHide(delay: Duration = .seconds(4)) {
        guard autoHideWhenDocked,
              isActive,
              !isVisuallyHidden else { return }
        autoHideTask?.cancel()
        autoHideTask = Task { @MainActor [weak self] in
            // Some iOS releases do not publish isPictureInPictureSuspended when the
            // user swipes a video-call PiP to an edge. Use that signal when it does
            // arrive, but retain this bounded fallback so the feature is reliable.
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled,
                  let self,
                  self.autoHideWhenDocked,
                  self.isActive,
                  !self.isVisuallyHidden else { return }
            self.hideDockedPresentation()
        }
    }

    private func hideDockedPresentation() {
        guard let videoCallContentController else { return }
        isVisuallyHidden = true
        UIView.performWithoutAnimation {
            videoCallContentController.preferredContentSize = Self.hiddenFrameSize
            videoCallImageView?.isHidden = true
            videoCallContentController.view.layoutIfNeeded()
        }
        recoverLiveActivityAfterTransition?()
    }

    private func restoreVisiblePresentation() {
        autoHideTask?.cancel()
        autoHideTask = nil
        isVisuallyHidden = false
        UIView.performWithoutAnimation {
            videoCallContentController?.preferredContentSize = Self.frameSize
            videoCallImageView?.isHidden = false
            videoCallContentController?.view.layoutIfNeeded()
        }
    }

    private func refreshPossibleState() {
        isPossible = pictureInPictureController?.isPictureInPicturePossible ?? false
    }

    private func renderLatest() {
        let content = TelemetryVideoFrameView(
            data: latestData,
            showPower: showPower,
            showTemperatures: showTemperatures,
            layout: layout,
            temperatureSelection: temperatureSelection
        )
        .frame(width: Self.frameSize.width, height: Self.frameSize.height)
        .environment(\.colorScheme, .dark)
        .environment(\.locale, .current)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        renderer.isOpaque = true
        guard let image = renderer.cgImage else { return }
        videoCallImageView?.image = UIImage(cgImage: image)
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.refreshPossibleState()
        }
    }

}

extension TelemetryPictureInPictureController: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerWillStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        guard self.pictureInPictureController === pictureInPictureController else { return }
        isActive = true
        errorMessage = nil
    }

    func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        guard self.pictureInPictureController === pictureInPictureController else { return }
        guard isStarting else { return }
        completeStartAttempt(startAttempt)
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: any Error
    ) {
        guard self.pictureInPictureController === pictureInPictureController else { return }
        failStartAttempt(startAttempt, message: "Picture in Picture could not start.")
    }

    func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        guard self.pictureInPictureController === pictureInPictureController else { return }
        invalidateStartAttempt()
        isStarting = false
        isActive = false
        restoreVisiblePresentation()
        attachToPendingPreviewIfNeeded()
        refreshPossibleState()
        recoverLiveActivityAfterTransition?()
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(true)
    }
}
