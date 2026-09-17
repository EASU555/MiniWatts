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
    /// ActivityKit can take a moment to publish a newly requested activity through
    /// `Activity.activities`. Do not mistake that short hand-off for a vanished
    /// activity and create a duplicate.
    private static let requestGraceInterval: TimeInterval = 3

    private var activity: Activity<MiniWattsActivityAttributes>?
    private var lastRequestAt = Date.distantPast
    private var lastUpdate = Date.distantPast
    private var lastLeadingItem: LiveActivityLeadingItem?
    private var lastMetric: LiveActivityMetric?
    private var pendingUpdate: ActivityContent<MiniWattsActivityAttributes.ContentState>?
    private var updateTask: Task<Void, Never>?
    /// Serializes an explicit stop/restart so an asynchronous end from the old
    /// activity can never race with, or accidentally occupy the slot needed by,
    /// the replacement.
    private var lifecycleTask: Task<Void, Never>?
    private var lifecycleGeneration = 0

    init() { synchronizeActivityWithSystem() }

    static var areActivitiesEnabled: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    var isRunning: Bool { activity != nil }

    func reconcile(snapshot: PowerSnapshot,
                   leadingItem: LiveActivityLeadingItem,
                   selectedMetric: LiveActivityMetric,
                   enabled: Bool,
                   forceUpdate: Bool = false) {
        guard enabled else {
            endIfNeeded()
            return
        }

        // `activityState` on a retained Activity object can lag behind the system
        // removing it. The static list is ActivityKit's source of truth for the
        // app's current activities, so reconcile the cached reference every tick.
        // This is what lets an enabled activity recover without killing the app.
        synchronizeActivityWithSystem()

        let state = Self.contentState(from: snapshot,
                                      leadingItem: leadingItem,
                                      selectedMetric: selectedMetric)
        let now = snapshot.date

        if activity == nil {
            guard lifecycleTask == nil else { return }
            guard Self.areActivitiesEnabled else { return }
            requestActivity(state: state,
                            leadingItem: leadingItem,
                            selectedMetric: selectedMetric,
                            at: now)
            return
        }

        guard forceUpdate
                || leadingItem != lastLeadingItem
                || selectedMetric != lastMetric
                || now.timeIntervalSince(lastUpdate) >= Self.updateInterval else { return }

        lastUpdate = now
        lastLeadingItem = leadingItem
        lastMetric = selectedMetric
        pendingUpdate = content(for: state, at: now)
        beginUpdatingIfNeeded()
    }

    /// Ends every activity from this app, waits for ActivityKit to release the
    /// system presentation, then requests a completely new one. Use this for an
    /// explicit user restart: a cached activity can remain `.active` even when its
    /// Dynamic Island presentation has disappeared, which cannot be diagnosed from
    /// `activityState` alone.
    func restart(snapshot: PowerSnapshot,
                 leadingItem: LiveActivityLeadingItem,
                 selectedMetric: LiveActivityMetric) {
        let state = Self.contentState(from: snapshot,
                                      leadingItem: leadingItem,
                                      selectedMetric: selectedMetric)
        let now = snapshot.date
        let activityIDs = allKnownActivityIDs()

        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        lifecycleTask?.cancel()
        lifecycleTask = nil
        resetLocalActivity()

        lifecycleTask = Task { @MainActor [weak self] in
            await Self.endActivities(withIDs: activityIDs)
            guard !Task.isCancelled,
                  let self,
                  self.lifecycleGeneration == generation else { return }

            // ActivityKit removes ended activities asynchronously. A short bounded
            // hand-off avoids requesting the replacement while the old UI still
            // owns the app's Live Activity slot.
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled,
                  self.lifecycleGeneration == generation else { return }

            self.requestActivity(state: state,
                                 leadingItem: leadingItem,
                                 selectedMetric: selectedMetric,
                                 at: now)
            if self.lifecycleGeneration == generation {
                self.lifecycleTask = nil
            }
        }
    }

    /// Repairs an activity as soon as the app becomes interactive again. Starting
    /// a Live Activity is foreground-only, so this is the first reliable moment to
    /// replace one that iOS ended while the process was suspended.
    func recoverAfterEnteringForeground(
        snapshot: PowerSnapshot,
        leadingItem: LiveActivityLeadingItem,
        selectedMetric: LiveActivityMetric
    ) {
        synchronizeActivityWithSystem()
        let needsReplacement: Bool
        if let activity {
            switch activity.activityState {
            case .active, .pending:
                needsReplacement = snapshot.date.timeIntervalSince(lastUpdate)
                    >= Self.staleInterval
            case .stale, .ended, .dismissed:
                needsReplacement = true
            @unknown default:
                needsReplacement = true
            }
        } else {
            needsReplacement = true
        }

        if needsReplacement {
            restart(snapshot: snapshot,
                    leadingItem: leadingItem,
                    selectedMetric: selectedMetric)
        } else {
            reconcile(snapshot: snapshot,
                      leadingItem: leadingItem,
                      selectedMetric: selectedMetric,
                      enabled: true,
                      forceUpdate: true)
        }
    }

    func endIfNeeded() {
        // Capture every ID before clearing local state. Older recovery races could
        // leave more than one activity behind, and ending only `.first` allowed the
        // remainder to consume the system activity limit.
        let activityIDs = allKnownActivityIDs()
        lifecycleGeneration &+= 1
        lifecycleTask?.cancel()
        lifecycleTask = nil
        resetLocalActivity()
        guard !activityIDs.isEmpty else { return }

        // Only immutable IDs cross the actor boundary. Reacquiring ActivityKit's
        // objects in the detached task avoids sending framework objects across the
        // Swift 6 isolation boundary.
        Task.detached {
            await Self.endActivities(withIDs: activityIDs)
        }
    }

    private func requestActivity(
        state: MiniWattsActivityAttributes.ContentState,
        leadingItem: LiveActivityLeadingItem,
        selectedMetric: LiveActivityMetric,
        at date: Date
    ) {
        guard Self.areActivitiesEnabled else { return }
        do {
            let requested = try Activity.request(
                attributes: MiniWattsActivityAttributes(startedAt: date),
                content: content(for: state, at: date),
                pushType: nil
            )
            activity = requested
            lastRequestAt = date
            lastUpdate = date
            lastLeadingItem = leadingItem
            lastMetric = selectedMetric
        } catch {
            // Live Activities can be disabled or the system-wide activity limit
            // can be full. The next foreground tick can retry, while the explicit
            // restart button remains available without force-quitting the app.
        }
    }

    private func allKnownActivityIDs() -> Set<String> {
        Set(
            Activity<MiniWattsActivityAttributes>.activities.map(\.id)
                + [activity?.id].compactMap { $0 }
        )
    }

    nonisolated private static func endActivities(withIDs activityIDs: Set<String>) async {
        guard !activityIDs.isEmpty else { return }
        for current in Activity<MiniWattsActivityAttributes>.activities
            where activityIDs.contains(current.id) {
            await current.end(nil, dismissalPolicy: .immediate)
        }
    }

    /// Keeps the cached object aligned with ActivityKit's current activity list.
    /// A force-quit used to repair this accidentally because `init` rebuilt the
    /// cache from this list; doing the same reconciliation continuously makes the
    /// controller self-healing while the process stays alive.
    private func synchronizeActivityWithSystem() {
        let currentActivities = Activity<MiniWattsActivityAttributes>.activities.filter {
            switch $0.activityState {
            case .active, .stale, .pending: return true
            case .ended, .dismissed: return false
            @unknown default: return false
            }
        }

        if let activity {
            switch activity.activityState {
            case .ended, .dismissed:
                resetLocalActivity()
            case .active, .stale, .pending:
                if let current = currentActivities.first(where: { $0.id == activity.id }) {
                    self.activity = current
                    return
                }
                guard Date.now.timeIntervalSince(lastRequestAt) >= Self.requestGraceInterval else {
                    return
                }
                resetLocalActivity()
            @unknown default:
                resetLocalActivity()
            }
        }

        if let current = currentActivities.first {
            activity = current
            lastUpdate = .distantPast
            lastLeadingItem = nil
            lastMetric = nil
        }
    }

    private func resetLocalActivity() {
        activity = nil
        lastRequestAt = .distantPast
        lastUpdate = .distantPast
        lastLeadingItem = nil
        lastMetric = nil
        pendingUpdate = nil
        updateTask?.cancel()
        updateTask = nil
    }

    private func beginUpdatingIfNeeded() {
        guard updateTask == nil else { return }
        updateTask = Task { @MainActor [weak self] in
            await self?.drainPendingUpdates()
        }
    }

    /// Sends at most one update at a time and skips directly to the newest snapshot
    /// when more sensor ticks arrive while ActivityKit is busy.
    private func drainPendingUpdates() async {
        while !Task.isCancelled, let content = pendingUpdate {
            pendingUpdate = nil
            guard let activity else { break }

            switch activity.activityState {
            case .active, .stale:
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
                    resetLocalActivity()
                }
            case .pending:
                // Keep the latest value ready until the system finishes presenting
                // the newly requested activity.
                pendingUpdate = content
                try? await Task.sleep(for: .milliseconds(250))
            case .ended, .dismissed:
                resetLocalActivity()
            @unknown default:
                pendingUpdate = nil
            }
        }
        updateTask = nil

        // A sensor tick can enqueue a value during the final suspension point.
        if pendingUpdate != nil {
            beginUpdatingIfNeeded()
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
        leadingItem: LiveActivityLeadingItem,
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
            sampledAt: snapshot.date,
            leadingItem: leadingItem,
            selectedMetric: selectedMetric,
            isWireless: snapshot.isWirelessInput
        )
    }
}
