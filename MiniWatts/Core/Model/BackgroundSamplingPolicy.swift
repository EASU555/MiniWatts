/// A Live Activity does not keep the app's sensor loop alive. An explicitly
/// opened PiP does, including its start and stop transitions. Keep this policy
/// separate from AVKit so a future lifecycle edit cannot silently regress it.
nonisolated enum BackgroundSamplingPolicy {
    static func keepsSampling(pipActive: Bool, pipStarting: Bool, pipStopping: Bool) -> Bool {
        pipActive || pipStarting || pipStopping
    }
}
