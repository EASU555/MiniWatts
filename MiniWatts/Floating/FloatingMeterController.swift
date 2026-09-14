import AVFoundation
import AVKit
import SwiftUI

/// The live readout as a floating window, drawn through Picture in Picture.
///
/// Why this surface exists at all: a widget shows what it read at its last timeline
/// reload, and iOS hands out roughly one reload every 15 to 60 minutes; a live
/// activity can only be updated by the app while the app is running, because push
/// updates need a server and a team certificate. Neither can show a number that
/// moves once a second while you are somewhere else. PiP can: the system keeps the
/// app alive to produce frames, so MiniWatts keeps reading the sensors and paints
/// each reading into the window.
///
/// The price is the audio background mode in `Info.plist` — PiP is built on the
/// media playback stack and will not start without it. Nothing is ever played: the
/// session is `.mixWithOthers` and carries no audio, so music keeps playing.
///
/// Everything here is one process-wide instance, injected from `MiniWattsApp`: the
/// layer PiP draws from has to stay in the window hierarchy for the whole life of
/// the app, and Settings — where the button lives — is a sheet that comes and goes.
@Observable
final class FloatingMeterController {
    enum Status: Equatable {
        /// No PiP on this device.
        case unsupported
        case idle
        /// The system will not open a window yet — usually because no frame has been
        /// painted into the layer.
        case notReady
        case starting
        case running
        /// The system refused. The message is AVKit's, and is shown as raw detail.
        case failed(String)
    }

    private(set) var status: Status
    /// The system will only open a window once the layer has painted a frame and is
    /// on screen, so the button waits for this.
    private(set) var isReady = false

    var isRunning: Bool { status == .running || status == .starting }

    /// The layer PiP draws from, hosted off screen by `RootView`.
    let layer = AVSampleBufferDisplayLayer()

    /// 16:9, rendered at 2× — the window is around 160 pt wide, and PiP takes the
    /// frame's own dimensions as its aspect ratio.
    private static let frameSize = CGSize(width: 320, height: 180)
    private static let frameScale: CGFloat = 2

    private var controller: AVPictureInPictureController?
    private var proxy: Proxy?
    private var pool: CVPixelBufferPool?
    private var poolSize = CGSize.zero
    private var lastFrame = Date.distantPast

    init() {
        status = AVPictureInPictureController.isPictureInPictureSupported() ? .idle : .unsupported
        layer.videoGravity = .resizeAspect
    }

    // MARK: Frames

    /// Paints one reading. Called from the one-second tick, which keeps running
    /// while the window is open — that is the whole point of the window.
    func render(_ reading: ChargeReading) {
        guard status != .unsupported else { return }
        // The tick is already once a second; this only guards against a burst.
        guard Date.now.timeIntervalSince(lastFrame) >= 0.4 else { return }
        lastFrame = .now

        guard let sample = makeSample(reading) else { return }
        let renderer = layer.sampleBufferRenderer
        // A failed renderer stays failed until it is flushed, and then swallows
        // every frame in silence — which looks exactly like a frozen reading.
        if renderer.status == .failed { renderer.flush() }
        renderer.enqueue(sample)

        // Built here rather than in `start()`: `isPictureInPicturePossible` is the
        // controller's own answer, so a controller that only exists once the window
        // has been asked for can never report that the window is available — which
        // left the button disabled forever.
        let possible = makeController()?.isPictureInPicturePossible ?? false
        if possible != isReady { isReady = possible }
        if possible, status == .notReady { status = .idle }
    }

    // MARK: Start and stop

    func start() {
        guard status != .unsupported, !isRunning else { return }
        guard let controller = makeController() else {
            status = .notReady
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            // Mixed, and silent: PiP needs a playback session to exist, not to be
            // heard. Without `.mixWithOthers` this would stop whatever is playing.
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            status = .failed(error.localizedDescription)
            return
        }
        // Asking anyway when the system says no gets silence — no window, no delegate
        // callback, nothing to report — so that case is answered here instead.
        guard controller.isPictureInPicturePossible else {
            status = .notReady
            return
        }
        status = .starting
        controller.startPictureInPicture()
        // And a start that is accepted but never confirmed would leave the button
        // spinning on `.starting` for the rest of the run.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard let self, status == .starting else { return }
            status = .notReady
        }
    }

    func stop() {
        controller?.stopPictureInPicture()
    }

    private func makeController() -> AVPictureInPictureController? {
        if let controller { return controller }
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return nil }
        let proxy = Proxy(owner: self)
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: layer,
                                                                playbackDelegate: proxy)
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = proxy
        controller.requiresLinearPlayback = true
        // Undocumented, and the reason the window is a readout rather than a video
        // player: it drops the play/pause and skip buttons that AVKit otherwise
        // draws over the frame. Guarded by a responds check — if it ever goes away
        // the window still works, with transport controls nobody can use.
        let selector = NSSelectorFromString("setControlsStyle:")
        if controller.responds(to: selector) {
            controller.setValue(1, forKey: "controlsStyle")
        }
        self.controller = controller
        self.proxy = proxy
        return controller
    }

    fileprivate func didStart() {
        status = .running
    }

    fileprivate func didStop() {
        status = .idle
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    fileprivate func didFail(_ error: Error) {
        status = .failed(error.localizedDescription)
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    // MARK: Rendering

    private func makeSample(_ reading: ChargeReading) -> CMSampleBuffer? {
        let renderer = ImageRenderer(content: FloatingMeterFrame(reading: reading)
            .frame(width: Self.frameSize.width, height: Self.frameSize.height))
        renderer.scale = Self.frameScale
        renderer.isOpaque = true
        guard let image = renderer.cgImage else { return nil }

        let pixels = CGSize(width: CGFloat(image.width), height: CGFloat(image.height))
        guard let pool = pixelBufferPool(pixels) else { return nil }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        let drawn = CGContext(data: CVPixelBufferGetBaseAddress(buffer),
                              width: image.width,
                              height: image.height,
                              bitsPerComponent: 8,
                              bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                  | CGBitmapInfo.byteOrder32Little.rawValue)
        drawn?.draw(image, in: CGRect(origin: .zero, size: pixels))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        guard drawn != nil else { return nil }

        var format: CMFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                           imageBuffer: buffer,
                                                           formatDescriptionOut: &format) == noErr,
              let format else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
                                                       imageBuffer: buffer,
                                                       formatDescription: format,
                                                       sampleTiming: &timing,
                                                       sampleBufferOut: &sample) == noErr,
              let sample else { return nil }
        // There is no timebase driving this layer — one frame a second, each shown
        // the moment it arrives.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let entry = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(entry,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }

    private func pixelBufferPool(_ size: CGSize) -> CVPixelBufferPool? {
        if let pool, poolSize == size { return pool }
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: Int(size.width),
            kCVPixelBufferHeightKey: Int(size.height),
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var created: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil,
                                      attributes as CFDictionary, &created) == kCVReturnSuccess,
              let created else { return nil }
        pool = created
        poolSize = size
        return created
    }

    /// AVKit's callbacks are not main-actor annotated, so they cannot be witnessed
    /// by this project's (main-actor by default) methods. They do arrive on the main
    /// thread, hence `assumeIsolated` rather than a hop, which would report a
    /// stopped window a frame late.
    private final class Proxy: NSObject, AVPictureInPictureControllerDelegate,
                               AVPictureInPictureSampleBufferPlaybackDelegate {
        private weak var owner: FloatingMeterController?

        init(owner: FloatingMeterController) {
            self.owner = owner
        }

        nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
            MainActor.assumeIsolated { owner?.didStart() }
        }

        nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
            MainActor.assumeIsolated { owner?.didStop() }
        }

        nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                    failedToStartPictureInPictureWithError error: any Error) {
            MainActor.assumeIsolated { owner?.didFail(error) }
        }

        /// Tapping the window's restore button brings MiniWatts back. There is no
        /// player UI to put back together, so the window just closes.
        nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
            completionHandler(true)
        }

        // The window is a readout, not a player: it is always live, never paused,
        // and there is nothing to seek.
        nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                    setPlaying playing: Bool) {}

        nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
            CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
        }

        nonisolated func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool {
            false
        }

        nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                    didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

        nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                    skipByInterval skipInterval: CMTime,
                                                    completion completionHandler: @escaping () -> Void) {
            completionHandler()
        }

        /// No sound of ours to protect, and silencing another app's would be rude.
        nonisolated func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(_ controller: AVPictureInPictureController) -> Bool {
            false
        }
    }
}
