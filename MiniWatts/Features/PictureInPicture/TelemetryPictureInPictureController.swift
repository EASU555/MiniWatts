import AVFoundation
import AVKit
import CoreMedia
import CoreVideo
import Observation
import ObjectiveC.runtime
import SwiftUI
import UIKit

nonisolated enum TelemetryPictureInPictureLayout: String, CaseIterable, Identifiable {
    case together
    case separatePages

    var id: Self { self }
}

nonisolated enum TelemetryPictureInPictureHideStatus: Hashable {
    case disabled
    case waitingForDock
    case hiddenAfterPublicDetection
    case hiddenAfterProxyDetection
    case hiddenAfterPositionDetection
    case hiddenAfterDelay
    case hideUnavailable

    var label: LocalizedStringResource {
        switch self {
        case .disabled: "Automatic hiding is off"
        case .waitingForDock: "Waiting for side docking"
        case .hiddenAfterPublicDetection: "Hidden after system detection"
        case .hiddenAfterProxyDetection: "Hidden after internal PiP detection"
        case .hiddenAfterPositionDetection: "Hidden after edge-position detection"
        case .hiddenAfterDelay: "Hidden by four-second fallback"
        case .hideUnavailable: "PiP hide controls unavailable"
        }
    }
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
    private static let hiddenHostedWindowSize = CGSize(width: 640, height: 0.1)

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
            hideStatus = .disabled
        }
    }

    private(set) var isActive = false
    private(set) var isStarting = false
    private(set) var isPossible = false
    private(set) var isVisuallyHidden = false
    private(set) var hideStatus = TelemetryPictureInPictureHideStatus.waitingForDock
    private(set) var errorMessage: LocalizedStringResource?

    @ObservationIgnored private(set) var displayLayer = AVSampleBufferDisplayLayer()
    @ObservationIgnored private var pictureInPictureController: AVPictureInPictureController?
    @ObservationIgnored private var pictureInPicturePossibleObservation: NSKeyValueObservation?
    @ObservationIgnored private var pictureInPictureSuspendedObservation: NSKeyValueObservation?
    @ObservationIgnored private var playbackTimebase: CMTimebase?
    @ObservationIgnored private var dockingMonitorTask: Task<Void, Never>?
    @ObservationIgnored private var windowHideTask: Task<Void, Never>?
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
        autoHideWhenDocked = false
        super.init()
        UserDefaults.standard.set(false, forKey: Self.autoHideWhenDockedKey)
        hideStatus = .disabled

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
        restorePictureInPictureWindow()

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
        renderLatest()
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
        restorePictureInPictureWindow()
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
        let controllerID = ObjectIdentifier(controller)
        pictureInPicturePossibleObservation = controller.observe(
            \.isPictureInPicturePossible,
            options: [.initial, .new]
        ) { [weak self] _, change in
            let possible = change.newValue ?? false
            Task { @MainActor [weak self] in
                self?.isPossible = possible
            }
        }
        pictureInPictureSuspendedObservation = controller.observe(
            \.isPictureInPictureSuspended,
            options: [.initial, .new]
        ) { [weak self] _, change in
            let isDocked = change.newValue ?? false
            Task { @MainActor [weak self] in
                guard let self,
                      let current = self.pictureInPictureController,
                      ObjectIdentifier(current) == controllerID else { return }
                if isDocked {
                    self.hideStatus = .disabled
                } else if !self.isVisuallyHidden {
                    self.hideStatus = .disabled
                }
            }
        }
    }

    private func rebuildRenderingPipeline() {
        restorePictureInPictureWindow()
        pictureInPicturePossibleObservation = nil
        pictureInPictureSuspendedObservation = nil
        pictureInPictureController = nil
        isPossible = false

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

    private func startAutomaticHideMonitoring() {
        guard autoHideWhenDocked,
              isActive,
              !isVisuallyHidden else { return }
        dockingMonitorTask?.cancel()
        dockingMonitorTask = Task { @MainActor [weak self] in
            // Side-stashing a PiP window is not the state represented by AVKit's
            // public `isPictureInPictureSuspended` API on every iOS release. Poll
            // the public controller, its Pegasus proxy and the hosted content view.
            // If none exposes the gesture, retain the four-second on-device fallback
            // that previously made the side tab collapse reliably.
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled,
                      let self,
                      self.autoHideWhenDocked,
                      self.isActive,
                      !self.isVisuallyHidden else { return }

                if self.pictureInPictureController?.isPictureInPictureSuspended == true {
                    self.scheduleWindowHide(status: .hiddenAfterPublicDetection)
                    return
                }
                if self.isPictureInPictureProxySuspended() {
                    self.scheduleWindowHide(status: .hiddenAfterProxyDetection)
                    return
                }
                if self.isPictureInPictureContentOffscreen() {
                    self.scheduleWindowHide(status: .hiddenAfterPositionDetection)
                    return
                }
            }

            guard !Task.isCancelled,
                  let self,
                  self.autoHideWhenDocked,
                  self.isActive,
                  !self.isVisuallyHidden else { return }
            self.scheduleWindowHide(status: .hiddenAfterDelay, delay: .zero)
        }
    }

    private func scheduleWindowHide(
        status: TelemetryPictureInPictureHideStatus,
        delay: Duration = .milliseconds(350)
    ) {
        guard autoHideWhenDocked, isActive, !isVisuallyHidden else { return }
        windowHideTask?.cancel()
        windowHideTask = Task { @MainActor [weak self] in
            // Let an observed edge-stash animation settle before changing only the
            // PiP presentation. The stream, audio session and Live Activity remain.
            try? await Task.sleep(for: delay)
            for _ in 0..<20 {
                guard !Task.isCancelled,
                      let self,
                      self.autoHideWhenDocked,
                      self.isActive else { return }
                if self.collapsePictureInPicturePresentation(status: status) { return }
                try? await Task.sleep(for: .milliseconds(100))
            }
            self?.hideStatus = .hideUnavailable
        }
    }

    @discardableResult
    private func collapsePictureInPicturePresentation(
        status: TelemetryPictureInPictureHideStatus
    ) -> Bool {
        let runtimeObjects = pictureInPictureRuntimeObjects()
        var changedPresentation = updateHostedWindowSize(
            Self.hiddenHostedWindowSize,
            runtimeObjects: runtimeObjects
        )
        let preferredSizeSelector = NSSelectorFromString("setPreferredContentSize:")
        for object in runtimeObjects where object.responds(to: preferredSizeSelector) {
            setPreferredContentSize(
                Self.hiddenHostedWindowSize,
                on: object,
                selector: preferredSizeSelector
            )
            changedPresentation = true
        }
        for contentController in runtimeObjects.compactMap({ $0 as? UIViewController }) {
            UIView.performWithoutAnimation {
                contentController.preferredContentSize = Self.hiddenHostedWindowSize
                contentController.view.alpha = 0
                contentController.view.isUserInteractionEnabled = false
                contentController.view.layoutIfNeeded()
            }
            changedPresentation = true
        }
        guard changedPresentation else { return false }
        setSystemControlsHidden(true)
        isVisuallyHidden = true
        hideStatus = status
        return true
    }

    private func restorePictureInPictureWindow() {
        dockingMonitorTask?.cancel()
        dockingMonitorTask = nil
        windowHideTask?.cancel()
        windowHideTask = nil
        isVisuallyHidden = false
    }

    private func setSystemControlsHidden(_ hidden: Bool) {
        guard let pictureInPictureController else { return }
        let selector = NSSelectorFromString("setControlsStyle:")
        guard pictureInPictureController.responds(to: selector) else { return }
        pictureInPictureController.setValue(hidden ? 2 : 0, forKey: "controlsStyle")
    }

    /// The sample-buffer route has its own internal content controller. Updating
    /// that controller follows the same preferred-content-size path that made the
    /// original video-call experiment collapse cleanly, without replacing the
    /// sample-buffer content source that is proven to coexist with Live Activity.
    private func currentPictureInPictureContentController() -> UIViewController? {
        pictureInPictureRuntimeObjects().first {
            $0 is UIViewController
                && NSStringFromClass(type(of: $0)).localizedCaseInsensitiveContains(
                    "PictureInPicture"
                )
        } as? UIViewController
    }

    private func currentPictureInPictureProxy() -> NSObject? {
        let selector = NSSelectorFromString(
            "updateHostedWindowSize:animationType:initialSpringVelocity:synchronizationFence:"
        )
        return pictureInPictureRuntimeObjects().first { $0.responds(to: selector) }
    }

    private func isPictureInPictureProxySuspended() -> Bool {
        guard let proxy = currentPictureInPictureProxy() else { return false }
        let selector = NSSelectorFromString("isPictureInPictureSuspended")
        guard proxy.responds(to: selector) else { return false }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        let getter = unsafeBitCast(proxy.method(for: selector), to: Getter.self)
        return getter(proxy, selector)
    }

    private func isPictureInPictureContentOffscreen() -> Bool {
        guard let view = currentPictureInPictureContentController()?.viewIfLoaded,
              let window = view.window,
              view.bounds.width > 20,
              view.bounds.height > 20 else { return false }
        let frame = view.convert(view.bounds, to: window.screen.coordinateSpace)
        let visible = frame.intersection(window.screen.bounds)
        guard !visible.isNull else { return true }
        let fullArea = frame.width * frame.height
        let visibleArea = visible.width * visible.height
        return fullArea > 0 && visibleArea / fullArea < 0.2
    }

    @discardableResult
    private func updateHostedWindowSize(
        _ size: CGSize,
        runtimeObjects: [NSObject]? = nil
    ) -> Bool {
        let selector = NSSelectorFromString(
            "updateHostedWindowSize:animationType:initialSpringVelocity:synchronizationFence:"
        )
        typealias Update = @convention(c) (
            AnyObject,
            Selector,
            CGSize,
            Int64,
            Double,
            AnyObject?
        ) -> Void
        var didUpdate = false
        for object in runtimeObjects ?? pictureInPictureRuntimeObjects()
        where object.responds(to: selector) {
            let update = unsafeBitCast(object.method(for: selector), to: Update.self)
            update(object, selector, size, 0, 0, nil)
            didUpdate = true
        }
        return didUpdate
    }

    private func setPreferredContentSize(
        _ size: CGSize,
        on object: NSObject,
        selector: Selector
    ) {
        typealias Setter = @convention(c) (AnyObject, Selector, CGSize) -> Void
        let setter = unsafeBitCast(object.method(for: selector), to: Setter.self)
        setter(object, selector, size)
    }

    /// AVKit 26 inserted AVPictureInPicturePlatformAdapter between the public
    /// controller and Pegasus. Follow only objects whose class name itself contains
    /// `PictureInPicture`; never follow UIKit controllers or windows back into the
    /// app. That strict boundary is what prevents the hide operation from touching
    /// MiniWatts' own scene.
    private func pictureInPictureRuntimeObjects() -> [NSObject] {
        guard let pictureInPictureController else { return [] }
        let root = pictureInPictureController as NSObject
        var result = [root]
        var queue: [(NSObject, Int)] = [(root, 0)]
        var visited: Set<ObjectIdentifier> = [ObjectIdentifier(root), ObjectIdentifier(self)]

        while !queue.isEmpty {
            let (object, depth) = queue.removeFirst()
            guard depth < 5 else { continue }
            var runtimeClass: AnyClass? = object_getClass(object)
            while let currentClass = runtimeClass, currentClass != NSObject.self {
                var count: UInt32 = 0
                guard let ivars = class_copyIvarList(currentClass, &count) else {
                    runtimeClass = class_getSuperclass(currentClass)
                    continue
                }
                defer { free(ivars) }
                for index in 0..<Int(count) {
                    let ivar = ivars[index]
                    guard let encoding = ivar_getTypeEncoding(ivar), encoding.pointee == 64,
                          let namePointer = ivar_getName(ivar) else { continue }
                    let ivarName = String(cString: namePointer).lowercased()
                    guard !ivarName.contains("delegate") else { continue }
                    guard let child = object_getIvar(object, ivar) as? NSObject else { continue }
                    let identifier = ObjectIdentifier(child)
                    guard visited.insert(identifier).inserted else { continue }
                    let className = NSStringFromClass(type(of: child))
                    guard className.localizedCaseInsensitiveContains("PictureInPicture") else {
                        continue
                    }
                    result.append(child)
                    queue.append((child, depth + 1))
                }
                runtimeClass = class_getSuperclass(currentClass)
            }

            for getterName in [
                "viewController",
                "contentViewController",
                "activeContentViewController",
                "activeVideoCallContentViewController",
                "pictureInPictureViewController"
            ] {
                let selector = NSSelectorFromString(getterName)
                guard object.responds(to: selector) else { continue }
                typealias Getter = @convention(c) (AnyObject, Selector) -> AnyObject?
                let getter = unsafeBitCast(object.method(for: selector), to: Getter.self)
                guard let child = getter(object, selector) as? NSObject else { continue }
                let identifier = ObjectIdentifier(child)
                guard visited.insert(identifier).inserted else { continue }
                let className = NSStringFromClass(type(of: child))
                guard className.localizedCaseInsensitiveContains("PictureInPicture") else {
                    continue
                }
                result.append(child)
                queue.append((child, depth + 1))
            }
        }
        return result
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
        restorePictureInPictureWindow()
        isStarting = false
        isActive = true
        hideStatus = .disabled
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
        attachToPendingPreviewIfNeeded()
    }

    func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        restorePictureInPictureWindow()
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
