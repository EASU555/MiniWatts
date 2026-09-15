import AVFoundation
import AVKit
import CoreMedia
import CoreVideo
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
    private static let frameSize = CGSize(width: 640, height: 360)

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

    private(set) var isActive = false
    private(set) var isStarting = false
    private(set) var isPossible = false
    private(set) var errorMessage: LocalizedStringResource?

    @ObservationIgnored private(set) var displayLayer = AVSampleBufferDisplayLayer()
    @ObservationIgnored private var pictureInPictureController: AVPictureInPictureController?
    @ObservationIgnored private var pictureInPicturePossibleObservation: NSKeyValueObservation?
    @ObservationIgnored private var playbackTimebase: CMTimebase?
    /// AVKit does not guarantee a terminal delegate callback when a start request is
    /// interrupted by an audio-session or scene transition. Keep one bounded attempt
    /// so Settings can never remain stuck in its loading state.
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var startAttempt = 0
    // Kept strongly while PiP is active so SwiftUI dismantling its representable
    // cannot also destroy the layer tree AVKit is still presenting.
    @ObservationIgnored private var sourceView: UIView?
    /// SwiftUI may replace the inline preview while a settings value changes.
    /// Moving the active sample-buffer layer to that replacement interrupts the
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
        super.init()

        configure(displayLayer)
        configurePlaybackTimebase()
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

        let needsAttachment = sourceView !== view || displayLayer.superlayer !== view.layer
        sourceView = view
        pendingSourceView = nil
        sourceViewWasDismantled = false
        if needsAttachment {
            displayLayer.removeFromSuperlayer()
            view.layer.addSublayer(displayLayer)
        }
        displayLayer.frame = view.bounds
        ensurePictureInPictureController()
        if needsAttachment {
            renderLatest()
        }
    }

    func layoutSource(in bounds: CGRect, hostedBy view: UIView) {
        guard sourceView === view else { return }
        displayLayer.frame = bounds
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
        displayLayer.removeFromSuperlayer()
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

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            errorMessage = "Picture in Picture audio mode could not start."
            return
        }

        guard let sourceView, sourceView.window != nil else {
            errorMessage = "Picture in Picture is not ready. Keep the preview visible and try again."
            return
        }

        // Prefer the controller that has already been displaying one-second frames.
        // Throwing that ready controller away on every tap creates a race in which
        // AVKit is asked to start before the replacement layer has been committed.
        sourceView.layoutIfNeeded()
        renderLatest()
        ensurePictureInPictureController()
        refreshPossibleState()
        if displayLayer.sampleBufferRenderer.status == .failed
            || pictureInPictureController == nil {
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
            displayLayer.sampleBufferRenderer.flush()
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
    }

    private func failStartAttempt(_ attempt: Int, message: LocalizedStringResource) {
        guard startAttempt == attempt else { return }
        invalidateStartAttempt()
        isStarting = false
        isActive = false
        errorMessage = message
        discardPictureInPictureController()
        displayLayer.sampleBufferRenderer.flush()
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
        guard pictureInPictureController == nil, isSupported else { return }
        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: displayLayer,
            playbackDelegate: self
        )
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        controller.requiresLinearPlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = false
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
    }

    private func rebuildRenderingPipeline() {
        discardPictureInPictureController()

        displayLayer.removeFromSuperlayer()
        let replacement = AVSampleBufferDisplayLayer()
        configure(replacement)
        displayLayer = replacement
        playbackTimebase = nil
        configurePlaybackTimebase()

        if let sourceView {
            sourceView.layer.addSublayer(replacement)
            replacement.frame = sourceView.bounds
        }
    }

    private func discardPictureInPictureController() {
        pictureInPicturePossibleObservation = nil
        pictureInPictureController?.delegate = nil
        pictureInPictureController = nil
        isPossible = false
    }

    private func attachToPendingPreviewIfNeeded() {
        guard !keepsSensorSamplingActive else { return }
        if let pendingSourceView, sourceView !== pendingSourceView {
            self.pendingSourceView = nil
            sourceView = pendingSourceView
            sourceViewWasDismantled = false
            displayLayer.removeFromSuperlayer()
            pendingSourceView.layer.addSublayer(displayLayer)
            displayLayer.frame = pendingSourceView.bounds
            renderLatest()
        } else if sourceViewWasDismantled {
            self.pendingSourceView = nil
            sourceViewWasDismantled = false
            displayLayer.removeFromSuperlayer()
            sourceView = nil
            isPossible = false
        }
    }

    private func configure(_ layer: AVSampleBufferDisplayLayer) {
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = UIColor.black.cgColor
        layer.preventsDisplaySleepDuringVideoPlayback = false
    }

    private func configurePlaybackTimebase() {
        guard playbackTimebase == nil else { return }
        let clock = CMClockGetHostTimeClock()
        var optionalTimebase: CMTimebase?
        guard CMTimebaseCreateWithSourceClock(
            allocator: kCFAllocatorDefault,
            sourceClock: clock,
            timebaseOut: &optionalTimebase
        ) == noErr, let timebase = optionalTimebase else { return }

        let now = CMClockGetTime(clock)
        guard CMTimebaseSetTime(timebase, time: now) == noErr,
              CMTimebaseSetRate(timebase, rate: 1) == noErr else { return }
        playbackTimebase = timebase
        displayLayer.controlTimebase = timebase
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
        guard let image = renderer.cgImage,
              let sampleBuffer = Self.makeSampleBuffer(from: image, size: Self.frameSize) else { return }

        // The renderer API is the iOS 17 replacement for enqueuing directly on the
        // display layer. Each buffer is marked for immediate display, so a fresh
        // telemetry frame replaces the previous one instead of building a queue.
        let videoRenderer = displayLayer.sampleBufferRenderer
        if videoRenderer.status == .failed {
            // Once AVFoundation loses decoder resources it rejects every later
            // frame until flushed. Recover on the next one-second telemetry tick
            // instead of leaving a permanent black window until process restart.
            videoRenderer.flush()
        }
        videoRenderer.enqueue(sampleBuffer)
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.refreshPossibleState()
        }
    }

    private static func makeSampleBuffer(from image: CGImage, size: CGSize) -> CMSampleBuffer? {
        let width = Int(size.width)
        let height = Int(size.height)
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        var optionalPixelBuffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault,
                                  width,
                                  height,
                                  kCVPixelFormatType_32BGRA,
                                  attributes as CFDictionary,
                                  &optionalPixelBuffer) == kCVReturnSuccess,
              let pixelBuffer = optionalPixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer),
              let context = CGContext(
                data: baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                    | CGImageAlphaInfo.premultipliedFirst.rawValue
              ) else { return nil }

        // ImageRenderer's CGImage is already in the bitmap context's row order.
        // Applying an additional UIKit-style Y flip here turns the entire monitor
        // upside down in both the inline preview and the PiP window.
        context.draw(image, in: CGRect(origin: .zero, size: size))

        var optionalFormat: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &optionalFormat
        ) == noErr, let format = optionalFormat else { return nil }

        let timestamp = CMClockGetTime(CMClockGetHostTimeClock())
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 1),
                                        presentationTimeStamp: timestamp,
                                        decodeTimeStamp: .invalid)
        var optionalSampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &optionalSampleBuffer
        ) == noErr, let sampleBuffer = optionalSampleBuffer else { return nil }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: true
        ) {
            let dictionary = unsafeBitCast(
                CFArrayGetValueAtIndex(attachments, 0),
                to: CFMutableDictionary.self
            )
            CFDictionarySetValue(
                dictionary,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        return sampleBuffer
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
        displayLayer.sampleBufferRenderer.flush()
        attachToPendingPreviewIfNeeded()
        refreshPossibleState()
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(true)
    }
}

extension TelemetryPictureInPictureController: AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        setPlaying playing: Bool
    ) {
        // Telemetry is a live source with no meaningful paused or seekable state.
        pictureInPictureController.invalidatePlaybackState()
    }

    func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> CMTimeRange {
        CMTimeRange(start: .zero, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        false
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {}

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping @Sendable () -> Void
    ) {
        completionHandler()
    }

    func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        // MiniWatts' manually enabled Live Activity uses an inaudible audio engine
        // to keep local PMU reads eligible in the background. Prohibiting background
        // audio here let PiP remain visible while silently suspending that engine,
        // so the Dynamic Island became stale until the app returned to the front.
        false
    }
}
