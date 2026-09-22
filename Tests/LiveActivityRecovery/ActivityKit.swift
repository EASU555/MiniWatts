// Test-only ActivityKit double. Never linked into the app or extension.
import Foundation

public protocol ActivityAttributes: Sendable {
    associatedtype ContentState: Codable, Hashable, Sendable
}
public enum ActivityState: Sendable { case active, stale, pending, ended, dismissed }
public enum ActivityUIDismissalPolicy: Sendable { case immediate }
public struct ActivityContent<State: Sendable>: Sendable {
    public let state: State
    public let relevanceScore: Double
    public init(state: State, staleDate: Date?, relevanceScore: Double) {
        self.state = state
        self.relevanceScore = relevanceScore
    }
}
public struct ActivityAuthorizationInfo {
    public init() {}
    public var areActivitiesEnabled: Bool { true }
}

private final class Store: @unchecked Sendable {
    static let shared = Store()
    let lock = NSLock()
    var activities: [String: AnyObject] = [:]
    var requests = 0
    var endings: [String] = []
    var updates: [String] = []
    var pending = false
    var endDelay: Duration = .zero
    var updateDelay: Duration = .zero
}

public enum TestSystem {
    public static var requests: Int { Store.shared.lock.withLock { Store.shared.requests } }
    public static var endings: [String] { Store.shared.lock.withLock { Store.shared.endings } }
    public static var updates: [String] { Store.shared.lock.withLock { Store.shared.updates } }
    public static func configure(pending: Bool = false, endDelay: Duration = .zero,
                                 updateDelay: Duration = .zero) {
        Store.shared.lock.withLock {
            Store.shared.pending = pending
            Store.shared.endDelay = endDelay
            Store.shared.updateDelay = updateDelay
        }
    }
    public static func reset() {
        Store.shared.lock.withLock {
            Store.shared.activities = [:]
            Store.shared.requests = 0
            Store.shared.endings = []
            Store.shared.updates = []
            Store.shared.pending = false
            Store.shared.endDelay = .zero
            Store.shared.updateDelay = .zero
        }
    }
}

public final class Activity<A: ActivityAttributes>: @unchecked Sendable {
    public let id = UUID().uuidString
    private let lock = NSLock()
    private var state: ActivityState
    private var payload: ActivityContent<A.ContentState>
    private let continuation: AsyncStream<ActivityState>.Continuation
    public let activityStateUpdates: AsyncStream<ActivityState>
    public var activityState: ActivityState { lock.withLock { state } }
    public var content: ActivityContent<A.ContentState> { lock.withLock { payload } }

    private init(content: ActivityContent<A.ContentState>, state: ActivityState) {
        self.payload = content
        self.state = state
        let stream = AsyncStream<ActivityState>.makeStream()
        activityStateUpdates = stream.stream
        continuation = stream.continuation
        continuation.yield(state)
    }
    public static var activities: [Activity<A>] {
        Store.shared.lock.withLock { Store.shared.activities.values.compactMap { $0 as? Activity<A> } }
    }
    public static func request(attributes: A, content: ActivityContent<A.ContentState>,
                               pushType: String?) throws -> Activity<A> {
        Store.shared.lock.withLock {
            let activity = Activity(content: content, state: Store.shared.pending ? .pending : .active)
            Store.shared.activities[activity.id] = activity
            Store.shared.requests += 1
            return activity
        }
    }
    public func end(_ content: ActivityContent<A.ContentState>?,
                    dismissalPolicy: ActivityUIDismissalPolicy) async {
        let delay = Store.shared.lock.withLock {
            Store.shared.endings.append(id)
            return Store.shared.endDelay
        }
        try? await Task.sleep(for: delay)
        lock.withLock { state = .ended }
        _ = Store.shared.lock.withLock { Store.shared.activities.removeValue(forKey: id) }
        continuation.yield(.ended)
        continuation.finish()
    }
    public func update(_ content: ActivityContent<A.ContentState>) async {
        let delay = Store.shared.lock.withLock {
            Store.shared.updates.append(id)
            return Store.shared.updateDelay
        }
        try? await Task.sleep(for: delay)
        lock.withLock { payload = content }
    }
}
