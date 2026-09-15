import ActivityKit
import Foundation

/// Owns the charging Live Activity without leaking ActivityKit into the sensor model.
/// A manually enabled activity owns a local background-refresh session until the
/// user turns it off. Updates are coalesced through one task: ActivityKit can take
/// longer than a sensor tick to accept an update, and launching a detached task per
/// second eventually leaves a queue of old values competing with the newest one.
@MainActor
final class ChargingLiveActivityController {
    private static let updateInterval: TimeInterval = 1
    /// `staleDate` is a presentation deadline, not an update timer. Four seconds was
    /// too close to the one-second sampling cadence and turned ordinary ActivityKit
    /// scheduling jitter into a false "paused" state. Updates remain once per second;
    /// this only gives the system enough grace before declaring the reading stale.
    private static let staleInterval: TimeInterval = 30

    private var activity: Activity<MiniWattsActivityAttributes>?
    private var lastUpdate = Date.distantPast
    private var lastMetric: LiveActivityMetric?
    private var pendingUpdate: ActivityContent<MiniWattsActivityAttributes.ContentState>?
    private var updateTask: Task<Void, Never>?
    private var updateGeneration = 0
    private var pendingStateStartedAt: Date?

    init() {
        activity = Self.currentActivity
    }

    static var areActivitiesEnabled: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    var isRunning: Bool {
        guard let activity else { return false }
        switch activity.activityState {
        case .active, .pending, .stale:
            return true
        case .ended, .dismissed:
            return false
        @unknown default:
            return false
        }
    }

    func reconcile(snapshot: PowerSnapshot,
                   selectedMetric: LiveActivityMetric,
                   enabled: Bool,
                   forceUpdate: Bool = false) {
        guard enabled else {
            endIfNeeded()
            return
        }

        adoptSystemActivityIfNeeded()

        let state = Self.contentState(from: snapshot, selectedMetric: selectedMetric)
        let now = snapshot.date

        if activity == nil {
            guard Self.areActivitiesEnabled else { return }
            do {
                activity = try Activity.request(
                    attributes: MiniWattsActivityAttributes(startedAt: now),
                    content: content(for: state, at: now),
                    pushType: nil
                )
                lastUpdate = now
                lastMetric = selectedMetric
            } catch {
                // Live Activities can be disabled or the system-wide activity limit
                // can be full. A request can also race ActivityKit publishing an
                // activity that this process briefly lost track of. Re-adopt that
                // system activity instead of remaining disconnected until relaunch.
                activity = Self.currentActivity
                if activity != nil {
                    lastUpdate = .distantPast
                    lastMetric = nil
                    pendingUpdate = content(for: state, at: now)
                    beginUpdatingIfNeeded()
                }
            }
            return
        }

        guard forceUpdate
                || selectedMetric != lastMetric
                || now.timeIntervalSince(lastUpdate) >= Self.updateInterval else { return }

        lastUpdate = now
        lastMetric = selectedMetric
        pendingUpdate = content(for: state, at: now)
        beginUpdatingIfNeeded()
    }

    func endIfNeeded() {
        let active = activity
            ?? Self.currentActivity
        clearActivityReference()
        guard let active else { return }
        let activityID = active.id
        Task.detached {
            guard let current = Activity<MiniWattsActivityAttributes>.activities
                .first(where: { $0.id == activityID }) else { return }
            await current.end(nil, dismissalPolicy: .immediate)
        }
    }

    private func beginUpdatingIfNeeded() {
        guard updateTask == nil else { return }
        updateGeneration &+= 1
        let generation = updateGeneration
        updateTask = Task { @MainActor [weak self] in
            await self?.drainPendingUpdates(generation: generation)
        }
    }

    /// Sends at most one update at a time and skips directly to the newest snapshot
    /// when more sensor ticks arrive while ActivityKit is busy.
    private func drainPendingUpdates(generation: Int) async {
        while !Task.isCancelled, let content = pendingUpdate {
            pendingUpdate = nil
            guard let activity else { break }

            switch activity.activityState {
            case .active, .stale:
                pendingStateStartedAt = nil
                // ActivityKit's update API is `@concurrent` in Swift 6. Reacquire
                // the activity by ID outside the main actor, then await that single
                // update before taking the next coalesced value.
                let activityID = activity.id
                let didUpdate = await Task.detached {
                    guard let current = Activity<MiniWattsActivityAttributes>.activities
                        .first(where: { $0.id == activityID }) else { return false }
                    await current.update(content)
                    return true
                }.value
                if !didUpdate, self.activity?.id == activityID {
                    clearActivityReference()
                }
            case .pending:
                // Keep the latest value ready until the system finishes presenting
                // the newly requested activity. A request that remains pending for
                // too long is wedged; end it so the next sensor tick can create a
                // clean activity instead of showing placeholders until app relaunch.
                let now = Date()
                if let pendingStateStartedAt,
                   now.timeIntervalSince(pendingStateStartedAt) >= 10 {
                    let activityID = activity.id
                    clearActivityReference()
                    Task.detached {
                        guard let current = Activity<MiniWattsActivityAttributes>.activities
                            .first(where: { $0.id == activityID }) else { return }
                        await current.end(nil, dismissalPolicy: .immediate)
                    }
                    break
                }
                if pendingStateStartedAt == nil {
                    pendingStateStartedAt = now
                }
                pendingUpdate = content
                try? await Task.sleep(for: .milliseconds(250))
            case .ended, .dismissed:
                clearActivityReference()
            @unknown default:
                pendingUpdate = nil
            }
        }
        guard generation == updateGeneration else { return }
        updateTask = nil

        // A sensor tick can enqueue a value during the final suspension point.
        if pendingUpdate != nil {
            beginUpdatingIfNeeded()
        }
    }

    /// ActivityKit owns the authoritative list. The local reference can disappear
    /// transiently after a delayed update or media-service transition even though
    /// the Dynamic Island is still on screen. Reacquiring it prevents a second
    /// request from colliding with the system activity and leaving both without data.
    private func adoptSystemActivityIfNeeded() {
        if let activity {
            switch activity.activityState {
            case .active, .pending, .stale:
                return
            case .ended, .dismissed:
                clearActivityReference()
            @unknown default:
                clearActivityReference()
            }
        }

        guard let existing = Self.currentActivity else { return }
        activity = existing
        lastUpdate = .distantPast
        lastMetric = nil
    }

    private func clearActivityReference() {
        activity = nil
        lastUpdate = .distantPast
        lastMetric = nil
        pendingUpdate = nil
        pendingStateStartedAt = nil
        updateGeneration &+= 1
        updateTask?.cancel()
        updateTask = nil
    }

    private static var currentActivity: Activity<MiniWattsActivityAttributes>? {
        Activity<MiniWattsActivityAttributes>.activities.first { activity in
            switch activity.activityState {
            case .active, .pending, .stale:
                return true
            case .ended, .dismissed:
                return false
            @unknown default:
                return false
            }
        }
    }

    private func content(for state: MiniWattsActivityAttributes.ContentState,
                         at date: Date) -> ActivityContent<MiniWattsActivityAttributes.ContentState> {
        ActivityContent(
            state: state,
            staleDate: date.addingTimeInterval(Self.staleInterval),
            relevanceScore: 1
        )
    }

    private static func contentState(
        from snapshot: PowerSnapshot,
        selectedMetric: LiveActivityMetric
    ) -> MiniWattsActivityAttributes.ContentState {
        let power: (watts: Double?, isBatterySide: Bool) = snapshot.externalConnected
            ? snapshot.chargingPower
            : (snapshot.batteryWatts.map(abs), true)
        return MiniWattsActivityAttributes.ContentState(
            chargeWatts: power.watts,
            powerIsBatterySide: power.isBatterySide,
            externalConnected: snapshot.externalConnected,
            batteryPercent: snapshot.percent,
            socTemperature: snapshot.socTemperature,
            batteryTemperature: snapshot.batteryTemperature,
            hottestTemperature: snapshot.hottestSensor?.value,
            hottestSensorName: snapshot.hottestSensor?.name,
            selectedMetric: selectedMetric,
            isWireless: snapshot.isWirelessInput
        )
    }
}
