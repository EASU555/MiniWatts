import Foundation

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

/// A stuck private sensor call cannot be cancelled safely. Keep its original
/// client alive and run at most one independent, HID-free fallback read while
/// waiting. Never publish an old or superseded read as a fresh measurement.
nonisolated struct SensorSamplingCoordinator {
    enum Source: Equatable, Sendable { case primary, fallback }
    struct Ticket: Equatable, Sendable {
        let source: Source
        let generation: Int
        let startedAt: TimeInterval
    }
    enum Completion: Equatable { case discard, publish, recovered }

    private static let stallInterval: TimeInterval = 10
    private var primary = SensorSamplingGate()
    private var fallback = SensorSamplingGate()
    private var primaryStartedAt: TimeInterval?
    private(set) var isDegraded = false

    var isSampling: Bool { primary.isSampling }
    var primaryReadInFlight: Bool { primary.readInFlight }
    var fallbackReadInFlight: Bool { fallback.readInFlight }

    mutating func start(at now: TimeInterval) {
        primary.start()
        fallback.start()
        // Give an old, invalidated read a short chance to finish after resume.
        if primary.readInFlight { primaryStartedAt = now }
    }

    mutating func pause() {
        primary.pause()
        fallback.pause()
        isDegraded = false
    }

    mutating func poll(at now: TimeInterval) -> [Ticket] {
        guard isSampling else { return [] }
        if primary.readInFlight, let started = primaryStartedAt,
           now - started >= Self.stallInterval {
            isDegraded = true
        }
        var requests: [Ticket] = []
        if let generation = primary.beginRead() {
            primaryStartedAt = now
            requests.append(Ticket(source: .primary, generation: generation, startedAt: now))
        }
        if isDegraded, let generation = fallback.beginRead() {
            requests.append(Ticket(source: .fallback, generation: generation, startedAt: now))
        }
        return requests
    }

    mutating func finish(_ ticket: Ticket, at now: TimeInterval) -> Completion {
        switch ticket.source {
        case .primary:
            let accepted = primary.finishRead(generation: ticket.generation)
            primaryStartedAt = nil
            guard accepted else { return .discard }
            // The values could have been collected before a long blocking call.
            // Discard that sample and wait for a new, timely full read.
            guard now - ticket.startedAt < Self.stallInterval else {
                isDegraded = true
                return .discard
            }
            guard isDegraded else { return .publish }
            isDegraded = false
            // A fallback read already underway may complete later than this full
            // read. Invalidate it so it cannot overwrite the recovered values.
            fallback.pause()
            fallback.start()
            return .recovered
        case .fallback:
            let accepted = fallback.finishRead(generation: ticket.generation)
            return accepted && isDegraded ? .publish : .discard
        }
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
