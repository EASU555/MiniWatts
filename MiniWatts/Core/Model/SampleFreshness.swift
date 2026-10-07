import Foundation

/// UI status only: never substitutes readings or changes sensor sampling.
nonisolated enum SampleFreshness: Equatable, Sendable {
    case waiting, current, delayed, old

    static func classify(hasSample: Bool, age: TimeInterval) -> Self {
        guard hasSample else { return .waiting }
        guard age.isFinite else { return .old }
        if age >= 30 { return .old }
        if age > 5 { return .delayed }
        return .current
    }
}
