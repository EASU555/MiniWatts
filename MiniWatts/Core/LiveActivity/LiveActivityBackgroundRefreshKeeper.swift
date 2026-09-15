import AVFoundation
import Foundation

/// Keeps the sensor process eligible for background execution while a manually
/// enabled Live Activity needs local hardware readings. The extension cannot read
/// the phone's PMU itself, so an inaudible PCM stream keeps the app-side sampler
/// alive until the user disables the activity. The carrier contains a real but
/// effectively inaudible sub-bass signal: an all-zero buffer played at zero
/// volume can be treated as idle after leaving the foreground on some releases.
///
/// MiniWatts is sideload-only because it already relies on private IOKit APIs. This
/// technique is likewise not intended as an App Store distribution strategy.
@MainActor
final class LiveActivityBackgroundRefreshKeeper: NSObject {
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var carrier: AVAudioPCMBuffer?
    private var shouldRun = false
    private var needsRebuild = true
    private var observationTasks: [Task<Void, Never>] = []

    private(set) var isRunning = false

    override init() {
        super.init()
        rebuildAudioGraph()
        observeAudioLifecycle()
    }

    deinit {
        observationTasks.forEach { $0.cancel() }
    }

    /// Starts, repairs, or stops the keepalive and returns its actual state. Calling
    /// this on every sensor tick doubles as a health check after route changes.
    @discardableResult
    func setActive(_ shouldRun: Bool) -> Bool {
        self.shouldRun = shouldRun
        guard shouldRun else {
            stopAudioGraph()
            return false
        }

        if needsRebuild || engine == nil || player == nil || carrier == nil {
            rebuildAudioGraph()
        }
        guard let engine, let player, let carrier else {
            isRunning = false
            return false
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            if !engine.isRunning {
                try engine.start()
            }
            if !player.isPlaying {
                player.scheduleBuffer(carrier, at: nil, options: [.loops])
                player.play()
            }
            isRunning = engine.isRunning && player.isPlaying
            needsRebuild = !isRunning
        } catch {
            stopAudioGraph(markForRebuild: true)
        }
        return isRunning
    }

    private func rebuildAudioGraph() {
        stopAudioGraph()

        let newEngine = AVAudioEngine()
        let newPlayer = AVAudioPlayerNode()
        let sampleRate = 44_100.0
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 1
        ), let newCarrier = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: 44_100
        ) else {
            engine = nil
            player = nil
            carrier = nil
            needsRebuild = true
            return
        }

        newCarrier.frameLength = newCarrier.frameCapacity
        if let samples = newCarrier.floatChannelData?[0] {
            // 17 Hz sits below normal hearing and -100 dBFS is far beneath the
            // phone speaker's useful output, but the rendered PCM is not digital
            // silence. This keeps the audio render path genuine without producing
            // a useful audible signal or interrupting other audio.
            let frequency = 17.0
            let amplitude = 0.000_01
            for frame in 0..<Int(newCarrier.frameLength) {
                let phase = 2 * Double.pi * frequency * Double(frame) / sampleRate
                samples[frame] = Float(sin(phase) * amplitude)
            }
        }
        newEngine.attach(newPlayer)
        newEngine.connect(newPlayer, to: newEngine.mainMixerNode, format: format)
        newPlayer.volume = 1
        newEngine.prepare()

        engine = newEngine
        player = newPlayer
        carrier = newCarrier
        needsRebuild = false
    }

    private func stopAudioGraph(markForRebuild: Bool = false) {
        player?.stop()
        engine?.stop()
        isRunning = false
        needsRebuild = markForRebuild
    }

    private func observeAudioLifecycle() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        observationTasks.append(Task { @MainActor [weak self] in
            for await notification in center.notifications(
                named: AVAudioSession.interruptionNotification,
                object: session
            ) {
                guard !Task.isCancelled else { return }
                self?.handleAudioInterruption(notification)
            }
        })
        observationTasks.append(Task { @MainActor [weak self] in
            for await _ in center.notifications(
                named: AVAudioSession.mediaServicesWereResetNotification,
                object: session
            ) {
                guard !Task.isCancelled else { return }
                self?.handleMediaServicesReset()
            }
        })
        observationTasks.append(Task { @MainActor [weak self] in
            for await notification in center.notifications(
                named: .AVAudioEngineConfigurationChange
            ) {
                guard !Task.isCancelled else { return }
                self?.handleEngineConfigurationChange(notification)
            }
        })
        observationTasks.append(Task { @MainActor [weak self] in
            for await _ in center.notifications(
                named: AVAudioSession.routeChangeNotification,
                object: session
            ) {
                guard !Task.isCancelled else { return }
                self?.handleAudioRouteChange()
            }
        })
    }

    private func handleAudioInterruption(_ notification: Notification) {
        guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }

        switch type {
        case .began:
            // `isPlaying` can remain true after an interruption even though the
            // render thread has stopped, so force a clean graph restart on resume.
            stopAudioGraph(markForRebuild: true)
        case .ended:
            if shouldRun {
                setActive(true)
            }
        @unknown default:
            break
        }
    }

    private func handleMediaServicesReset() {
        // Apple requires audio objects to be recreated after the media server resets.
        rebuildAudioGraph()
        if shouldRun {
            setActive(true)
        }
    }

    private func handleEngineConfigurationChange(_ notification: Notification) {
        guard shouldRun,
              let changedEngine = notification.object as? AVAudioEngine,
              changedEngine === engine else { return }
        stopAudioGraph(markForRebuild: true)
        setActive(true)
    }

    private func handleAudioRouteChange() {
        guard shouldRun else { return }
        stopAudioGraph(markForRebuild: true)
        setActive(true)
    }
}
