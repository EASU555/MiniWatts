import AVFoundation

/// Keeps the sensor process eligible for background execution while a charging
/// Live Activity needs local hardware readings. A Live Activity extension cannot
/// read the phone's PMU itself, and a remote push server cannot know local sensor
/// values, so the existing audio background mode carries an inaudible PCM stream
/// only for the duration of an enabled, connected charge.
///
/// MiniWatts is sideload-only because it already relies on private IOKit APIs. This
/// technique is likewise not intended as an App Store distribution strategy.
@MainActor
final class LiveActivityBackgroundRefreshKeeper {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let silence: AVAudioPCMBuffer?

    private(set) var isRunning = false

    init() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)
        if let format,
           let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100) {
            buffer.frameLength = buffer.frameCapacity
            if let samples = buffer.floatChannelData?[0] {
                samples.initialize(repeating: 0, count: Int(buffer.frameLength))
            }
            silence = buffer
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            player.volume = 0
            engine.prepare()
        } else {
            silence = nil
        }
    }

    /// Starts, repairs, or stops the keepalive and returns its actual state.
    @discardableResult
    func setActive(_ shouldRun: Bool) -> Bool {
        guard shouldRun else {
            player.stop()
            engine.stop()
            isRunning = false
            return false
        }
        guard let silence else {
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
        } catch {
            player.stop()
            engine.stop()
            isRunning = false
        }
        return isRunning
    }
}
