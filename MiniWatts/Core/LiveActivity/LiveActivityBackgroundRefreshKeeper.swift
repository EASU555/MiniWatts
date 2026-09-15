import AVFoundation

/// Keeps the sensor process eligible for background execution while a manually
/// enabled Live Activity needs local hardware readings. The extension cannot read
/// the phone's PMU itself, so an inaudible PCM stream keeps the app-side sampler
/// alive until the user disables the activity.
///
/// MiniWatts is sideload-only because it already relies on private IOKit APIs. This
/// technique is likewise not intended as an App Store distribution strategy.
@MainActor
final class LiveActivityBackgroundRefreshKeeper: NSObject {
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var silence: AVAudioPCMBuffer?
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
            if isRunning || engine?.isRunning == true || player?.isPlaying == true {
                stopAudioGraph()
            }
            return false
        }

        // PowerMonitor calls this health check on every one-second sensor tick.
        // Reapplying the AVAudioSession category and activation while the graph is
        // already healthy races AVKit's PiP start transition on some devices. Keep
        // the common path idempotent; lifecycle notifications below still force a
        // rebuild after real interruptions and media-service resets.
        if !needsRebuild,
           let engine,
           let player,
           engine.isRunning,
           player.isPlaying {
            isRunning = true
            return true
        }

        if needsRebuild || engine == nil || player == nil || silence == nil {
            rebuildAudioGraph()
        }
        guard let engine, let player, let silence else {
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
                player.scheduleBuffer(silence, at: nil, options: [.loops])
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
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: 44_100,
            channels: 1
        ), let newSilence = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: 44_100
        ) else {
            engine = nil
            player = nil
            silence = nil
            needsRebuild = true
            return
        }

        newSilence.frameLength = newSilence.frameCapacity
        if let samples = newSilence.floatChannelData?[0] {
            samples.initialize(repeating: 0, count: Int(newSilence.frameLength))
        }
        newEngine.attach(newPlayer)
        newEngine.connect(newPlayer, to: newEngine.mainMixerNode, format: format)
        newPlayer.volume = 0
        newEngine.prepare()

        engine = newEngine
        player = newPlayer
        silence = newSilence
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
}
