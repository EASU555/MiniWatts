/// Owns permission to start a probe and publish its eventual result. Pausing
/// invalidates a blocking read without allowing a second read to overlap it.
nonisolated struct SensorSamplingGate {
    private(set) var isSampling = false
    private(set) var readInFlight = false
    private var generation = 0

    mutating func start() {
        isSampling = true
    }

    mutating func pause() {
        isSampling = false
        generation &+= 1
    }

    mutating func beginRead() -> Int? {
        guard isSampling, !readInFlight else { return nil }
        readInFlight = true
        return generation
    }

    mutating func finishRead(generation completedGeneration: Int) -> Bool {
        readInFlight = false
        return isSampling && completedGeneration == generation
    }
}

/// No observation is different from a reported unplug. In particular, failed
/// powerd and registry reads must not close an existing charging session.
nonisolated enum SamplingSessionAction: Equatable {
    case record
    case close
    case hold

    static func decide(externalConnection: Bool?) -> Self {
        switch externalConnection {
        case true: .record
        case false: .close
        case nil: .hold
        }
    }
}
