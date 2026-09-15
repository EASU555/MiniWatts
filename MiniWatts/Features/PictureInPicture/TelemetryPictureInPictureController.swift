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

nonisolated enum TelemetryPictureInPictureContentMode: String, CaseIterable, Identifiable {
    case liveReadings
    case hiddenCarrier

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

/// Owns either the one-frame-per-second telemetry stream or a video-call PiP
/// surface that iOS can shrink below the AVPlayerLayer minimum. PiP is user
/// initiated; while either route remains active, RootView keeps PowerMonitor's
/// sensor tick alive in the background.
@Observable
@MainActor
final class TelemetryPictureInPictureController: NSObject {
    private static let showPowerKey = "pictureInPictureShowPower"
    private static let showTemperaturesKey = "pictureInPictureShowTemperatures"
    private static let layoutKey = "pictureInPictureLayout"
    private static let temperatureSelectionKey = "pictureInPictureTemperatureSelection"
    private static let contentModeKey = "pictureInPictureContentMode"
    private static let frameSize = CGSize(width: 640, height: 360)
    private static let visibleVideoCallSize = CGSize(width: 300, height: 168.75)
    private static let hiddenVideoCallSize = CGSize(width: 300, height: 0.1)

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

    var contentMode: TelemetryPictureInPictureContentMode {
        didSet {
            UserDefaults.standard.set(contentMode.rawValue, forKey: Self.contentModeKey)
            guard contentMode != oldValue else { return }
            if keepsSensorSamplingActive {
                pendingPipelineRebuild = true
                stop()
            } else {
                rebuildRenderingPipeline()
            }
        }
    }

    private(set) var isActive = false
    private(set) var isStarting = false
    private(set) var isPossible = false
    private(set) var isVisuallyHidden = false
    private(set) var errorMessage: LocalizedStringResource?

    @ObservationIgnored private(set) var displayLayer = AVSampleBufferDisplayLayer()
    @ObservationIgnored private var videoCallContentController: AVPictureInPictureVideoCallViewController?
    @ObservationIgnored private var videoCallSourceView: UIView?
    @ObservationIgnored private var videoCallContentView: UIView?
    @ObservationIgnored private var pictureInPictureController: AVPictureInPictureController?
    @ObservationIgnored private var pictureInPicturePossibleObservation: NSKeyValueObservation?
    @ObservationIgnored private var pictureInPictureSuspendedObservation: NSKeyValueObservation?
    @ObservationIgnored private var playbackTimebase: CMTimebase?
    @ObservationIgnored private var pendingPipelineRebuild = false
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
        let storedContentMode = defaults.string(forKey: Self.contentModeKey)
        // Build 40 called the blank AVPlayer route `nativeCarrier`. Carry that
        // preference forward into the replacement VideoCall hidden route.
        contentMode = storedContentMode == "nativeCarrier"
            ? .hiddenCarrier
            : storedContentMode.flatMap(TelemetryPictureInPictureContentMode.init(rawValue:))
                ?? .liveReadings
        super.init()

        configure(displayLayer)
        configurePlaybackTimebase()
    }

    var isSupported: Bool {
        AVPictureInPictureController.isPictureInPictureSupported()
    }

    var hasSelectedContent: Bool {
        contentMode == .hiddenCarrier || showPower || showTemperatures
    }
    var keepsSensorSamplingActive: Bool { isActive || isStarting }

    func attach(to view: UIView) {
        if keepsSensorSamplingActive, sourceView !== view {
            pendingSourceView = view
            return
        }

        let activeSurfaceIsAttached = contentMode == .liveReadings
            ? displayLayer.superlayer === view.layer
            : videoCallSourceView?.superview === view
        let needsAttachment = sourceView !== view || !activeSurfaceIsAttached
        sourceView = view
        pendingSourceView = nil
        sourceViewWasDismantled = false
        if needsAttachment {
            displayLayer.removeFromSuperlayer()
            videoCallSourceView?.removeFromSuperview()
            attachActiveSurface(to: view)
        }
        layoutActiveSurface(in: view.bounds)
        ensurePictureInPictureController()
        if needsAttachment {
            renderLatest()
        }
    }

    func layoutSource(in bounds: CGRect, hostedBy view: UIView) {
        guard sourceView === view else { return }
        layoutActiveSurface(in: bounds)
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
        videoCallSourceView?.removeFromSuperview()
        sourceView = nil
        sourceViewWasDismantled = false
        isPossible = false
    }

    func update(snapshot: PowerSnapshot, thermalState: ProcessInfo.ThermalState) {
        latestData = TelemetryFrameData(snapshot: snapshot, thermalState: thermalState)
        guard contentMode == .liveReadings else { return }
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

        // Recreate the controller only after the media audio session is active and
        // the source layer is attached to a visible view. A controller created by
        // SwiftUI's early makeUIView pass can otherwise remain permanently unable
        // to enter PiP even after the preview begins displaying frames.
        sourceView?.layoutIfNeeded()
        rebuildRenderingPipeline()
        if contentMode == .liveReadings {
            renderLatest()
        }
        ensurePictureInPictureController()

        isStarting = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            // AVKit needs a committed, displayed frame before PiP becomes possible.
            // KVO normally updates the state immediately; the bounded poll also
            // covers devices that deliver the initial observation late.
            for _ in 0..<20 {
                refreshPossibleState()
                if isPossible { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard let controller = pictureInPictureController,
                  controller.isPictureInPicturePossible else {
                isStarting = false
                errorMessage = "Picture in Picture is not ready. Keep the preview visible and try again."
                return
            }
            controller.startPictureInPicture()
        }
    }

    func stop() {
        pictureInPictureController?.stopPictureInPicture()
    }

    /// The 0.1 pt path follows the public VideoCall PiP sizing mechanism used by
    /// GlobalRefresh-PiP. It changes AVKit's content size rather than moving or
    /// covering a system-owned PiP window.
    func setVisuallyHidden(_ hidden: Bool) {
        guard contentMode == .hiddenCarrier else { return }
        guard isActive else {
            errorMessage = "Start Picture in Picture before changing its hidden state."
            return
        }
        applyVideoCallGeometry(hidden: hidden)
    }

    private func ensurePictureInPictureController() {
        guard pictureInPictureController == nil, isSupported else { return }
        let controller: AVPictureInPictureController
        switch contentMode {
        case .liveReadings:
            let source = AVPictureInPictureController.ContentSource(
                sampleBufferDisplayLayer: displayLayer,
                playbackDelegate: self
            )
            controller = AVPictureInPictureController(contentSource: source)
        case .hiddenCarrier:
            configureVideoCallCarrier()
            guard let videoCallSourceView, let videoCallContentController else { return }
            let source = AVPictureInPictureController.ContentSource(
                activeVideoCallSourceView: videoCallSourceView,
                contentViewController: videoCallContentController
            )
            controller = AVPictureInPictureController(contentSource: source)
        }
        controller.delegate = self
        controller.requiresLinearPlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = false
        pictureInPictureController = controller
        // `controlsStyle` is the one part of the supplied AVPlayerLayer example
        // that differs from our stable sample-buffer implementation. Apply it as
        // soon as the standard PiP controller exists; iOS remains solely
        // responsible for dragging, edge docking and the restore affordance.
        setSystemControlsHidden()
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
                      ObjectIdentifier(current) == controllerID,
                      self.contentMode == .hiddenCarrier,
                      self.isActive,
                      !self.isVisuallyHidden else { return }
                self.applyVideoCallGeometry(hidden: true)
            }
        }
    }

    private func rebuildRenderingPipeline() {
        pictureInPicturePossibleObservation = nil
        pictureInPictureSuspendedObservation = nil
        pictureInPictureController = nil
        isPossible = false

        displayLayer.removeFromSuperlayer()
        videoCallSourceView?.removeFromSuperview()

        switch contentMode {
        case .liveReadings:
            tearDownVideoCallCarrier()
            let replacement = AVSampleBufferDisplayLayer()
            configure(replacement)
            displayLayer = replacement
            playbackTimebase = nil
            configurePlaybackTimebase()
        case .hiddenCarrier:
            configureVideoCallCarrier()
        }

        if let sourceView {
            attachActiveSurface(to: sourceView)
            layoutActiveSurface(in: sourceView.bounds)
        }
    }

    private func configureVideoCallCarrier() {
        guard videoCallContentController == nil else { return }

        let contentController = AVPictureInPictureVideoCallViewController()
        contentController.preferredContentSize = Self.visibleVideoCallSize
        contentController.view.backgroundColor = .clear
        contentController.view.isOpaque = false
        contentController.view.clipsToBounds = true

        let contentView = UIView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.backgroundColor = .clear
        contentView.isOpaque = false
        contentController.view.addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: contentController.view.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: contentController.view.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: contentController.view.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: contentController.view.bottomAnchor)
        ])

        let source = UIView(frame: CGRect(origin: .zero, size: Self.visibleVideoCallSize))
        source.backgroundColor = .clear
        source.isOpaque = false
        source.clipsToBounds = true

        videoCallContentController = contentController
        videoCallContentView = contentView
        videoCallSourceView = source
        isVisuallyHidden = false
    }

    private func tearDownVideoCallCarrier() {
        videoCallSourceView?.removeFromSuperview()
        videoCallContentView?.removeFromSuperview()
        videoCallSourceView = nil
        videoCallContentView = nil
        videoCallContentController = nil
        isVisuallyHidden = false
    }

    private func attachActiveSurface(to view: UIView) {
        switch contentMode {
        case .liveReadings:
            view.layer.addSublayer(displayLayer)
        case .hiddenCarrier:
            configureVideoCallCarrier()
            if let videoCallSourceView {
                view.addSubview(videoCallSourceView)
            }
        }
    }

    private func layoutActiveSurface(in bounds: CGRect) {
        displayLayer.frame = bounds
        guard contentMode == .hiddenCarrier, let videoCallSourceView else { return }
        let targetSize = isVisuallyHidden
            ? Self.hiddenVideoCallSize
            : Self.visibleVideoCallSize
        videoCallSourceView.frame = CGRect(
            x: bounds.midX - targetSize.width / 2,
            y: bounds.midY - targetSize.height / 2,
            width: targetSize.width,
            height: targetSize.height
        )
    }

    private func applyVideoCallGeometry(hidden: Bool) {
        guard let videoCallContentController else { return }
        let size = hidden ? Self.hiddenVideoCallSize : Self.visibleVideoCallSize
        isVisuallyHidden = hidden
        UIView.performWithoutAnimation {
            videoCallContentController.preferredContentSize = size
            if hidden {
                videoCallContentController.view.alpha = 0.01
                videoCallContentView?.alpha = 0.01
            } else {
                videoCallContentController.view.alpha = 1
                videoCallContentView?.alpha = 1
            }
            if let sourceView {
                layoutActiveSurface(in: sourceView.bounds)
                sourceView.layoutIfNeeded()
            }
            videoCallContentController.view.layoutIfNeeded()
        }
    }

    private func attachToPendingPreviewIfNeeded() {
        guard !keepsSensorSamplingActive else { return }
        if let pendingSourceView, sourceView !== pendingSourceView {
            self.pendingSourceView = nil
            sourceView = pendingSourceView
            sourceViewWasDismantled = false
            displayLayer.removeFromSuperlayer()
            videoCallSourceView?.removeFromSuperview()
            attachActiveSurface(to: pendingSourceView)
            layoutActiveSurface(in: pendingSourceView.bounds)
            if contentMode == .liveReadings {
                renderLatest()
            }
        } else if sourceViewWasDismantled {
            self.pendingSourceView = nil
            sourceViewWasDismantled = false
            displayLayer.removeFromSuperlayer()
            videoCallSourceView?.removeFromSuperview()
            sourceView = nil
            isPossible = false
        }
    }

    private func setSystemControlsHidden() {
        guard let pictureInPictureController else { return }
        let selector = NSSelectorFromString("setControlsStyle:")
        guard pictureInPictureController.responds(to: selector) else { return }
        pictureInPictureController.setValue(2, forKey: "controlsStyle")
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
        guard contentMode == .liveReadings else { return }
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
        isStarting = false
        isActive = true
        errorMessage = nil
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: any Error
    ) {
        isStarting = false
        isActive = false
        errorMessage = "Picture in Picture could not start."
        displayLayer.sampleBufferRenderer.flush()
        if pendingPipelineRebuild {
            pendingPipelineRebuild = false
            rebuildRenderingPipeline()
        }
        attachToPendingPreviewIfNeeded()
    }

    func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        isStarting = false
        isActive = false
        if contentMode == .hiddenCarrier {
            applyVideoCallGeometry(hidden: false)
        }
        displayLayer.sampleBufferRenderer.flush()
        if pendingPipelineRebuild {
            pendingPipelineRebuild = false
            rebuildRenderingPipeline()
        }
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
        // The telemetry stream and its media session must remain eligible while
        // PiP is active; otherwise the visible PiP can survive while its sensor
        // values and the Dynamic Island stop advancing in the background.
        false
    }
}
