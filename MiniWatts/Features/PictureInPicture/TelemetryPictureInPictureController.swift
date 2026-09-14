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

    init(snapshot: PowerSnapshot) {
        let input = snapshot.inputWatts
        date = snapshot.date
        externalConnected = snapshot.externalConnected
        isWireless = snapshot.isWirelessInput
        chargeWatts = input ?? snapshot.batteryWatts.map { max($0, 0) }
        powerIsBatterySide = input == nil
        batteryPercent = snapshot.percent
        socTemperature = snapshot.socTemperature
        batteryTemperature = snapshot.batteryTemperature
        chargerTemperature = snapshot.chargerTemperature
        hottestTemperature = snapshot.hottestSensor?.value
        hottestSensorName = snapshot.hottestSensor?.name
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

    private(set) var isActive = false
    private(set) var isStarting = false
    private(set) var isPossible = false
    private(set) var errorMessage: LocalizedStringResource?

    @ObservationIgnored let displayLayer = AVSampleBufferDisplayLayer()
    @ObservationIgnored private var pictureInPictureController: AVPictureInPictureController?
    @ObservationIgnored private var pictureInPicturePossibleObservation: NSKeyValueObservation?
    @ObservationIgnored private var playbackTimebase: CMTimebase?
    @ObservationIgnored private weak var sourceView: UIView?
    @ObservationIgnored private var latestData: TelemetryFrameData?

    override init() {
        let defaults = UserDefaults.standard
        showPower = defaults.object(forKey: Self.showPowerKey) as? Bool ?? true
        showTemperatures = defaults.object(forKey: Self.showTemperaturesKey) as? Bool ?? true
        layout = defaults.string(forKey: Self.layoutKey)
            .flatMap(TelemetryPictureInPictureLayout.init(rawValue:)) ?? .together
        super.init()

        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
        displayLayer.preventsDisplaySleepDuringVideoPlayback = false
        configurePlaybackTimebase()
    }

    var isSupported: Bool {
        AVPictureInPictureController.isPictureInPictureSupported()
    }

    var hasSelectedContent: Bool { showPower || showTemperatures }
    var keepsSensorSamplingActive: Bool { isActive || isStarting }

    func attach(to view: UIView) {
        let needsAttachment = sourceView !== view || displayLayer.superlayer !== view.layer
        sourceView = view
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

    func layoutSource(in bounds: CGRect) {
        displayLayer.frame = bounds
    }

    func detach(from view: UIView) {
        guard sourceView === view, !keepsSensorSamplingActive else { return }
        displayLayer.removeFromSuperlayer()
        sourceView = nil
        isPossible = false
    }

    func update(snapshot: PowerSnapshot) {
        latestData = TelemetryFrameData(snapshot: snapshot)
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
        configurePlaybackTimebase()
        sourceView?.layoutIfNeeded()
        renderLatest()
        rebuildPictureInPictureController()

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
                deactivateAudioSession()
                return
            }
            controller.startPictureInPicture()
        }
    }

    func stop() {
        pictureInPictureController?.stopPictureInPicture()
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
        pictureInPicturePossibleObservation = controller.observe(
            \.isPictureInPicturePossible,
            options: [.initial, .new]
        ) { [weak self] _, change in
            let possible = change.newValue ?? false
            Task { @MainActor [weak self] in
                self?.isPossible = possible
            }
        }
    }

    private func rebuildPictureInPictureController() {
        pictureInPicturePossibleObservation = nil
        pictureInPictureController = nil
        isPossible = false
        ensurePictureInPictureController()
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
            layout: layout
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
        displayLayer.sampleBufferRenderer.enqueue(sampleBuffer)
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

    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: [.notifyOthersOnDeactivation]
        )
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
        deactivateAudioSession()
    }

    func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        isStarting = false
        isActive = false
        refreshPossibleState()
        deactivateAudioSession()
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
        true
    }
}
