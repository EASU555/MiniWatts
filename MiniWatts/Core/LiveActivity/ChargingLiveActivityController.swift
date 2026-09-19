import ActivityKit
import Foundation
import UIKit

enum LiveActivityRecoveryStatus: Equatable {
    case idle
    case restarting
    case running
    case failed(String)
}

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
    /// A request that remains pending this long has normally lost its presentation
    /// hand-off. Likewise, an update that never returns must not hold the coalescing
    /// queue forever while the UI continues to claim that fresh values were sent.
    private static let operationTimeout: Duration = .seconds(8)
    private static let operationTimeoutSeconds: TimeInterval = 8
    private static let requestRetryInterval: TimeInterval = 5
    private static let systemReleaseTimeout: Duration = .seconds(5)
    private static let replacementAttemptCount = 4
    /// ActivityKit can take a moment to publish a newly requested activity through
    /// `Activity.activities`. Do not mistake that short hand-off for a vanished
    /// activity and create a duplicate.
    private static let requestGraceInterval: TimeInterval = 3

    private var activity: Activity<MiniWattsActivityAttributes>?
    private var lastRequestAt = Date.distantPast
    /// These are deliberately separate. Enqueue time is only for throttling; only
    /// the completion of ActivityKit's async update proves that the pipeline is
    /// still moving and may be used by foreground recovery.
    private var lastUpdateEnqueuedAt = Date.distantPast
    private var lastSuccessfulUpdateAt = Date.distantPast
    private var lastLeadingItem: LiveActivityLeadingItem?
    private var lastMetric: LiveActivityMetric?
    private var latestState: MiniWattsActivityAttributes.ContentState?
    private var pendingUpdate: ActivityContent<MiniWattsActivityAttributes.ContentState>?
    private var updateInFlight = false
    private var updateGeneration = 0
    private var inFlightActivityID: String?
    private var updateTimeoutTask: Task<Void, Never>?
    private var activityStateTask: Task<Void, Never>?
    private var pendingStateTimeoutTask: Task<Void, Never>?
    /// Serializes an explicit stop/restart so an asynchronous end from the old
    /// activity can never race with, or accidentally occupy the slot needed by,
    /// the replacement.
    private var lifecycleTask: Task<Void, Never>?
    private var lifecycleGeneration = 0
    private(set) var recoveryStatus = LiveActivityRecoveryStatus.idle {
        didSet {
            guard recoveryStatus != oldValue else { return }
            onRecoveryStatusChange?(recoveryStatus)
        }
    }

    var onRecoveryStatusChange: ((LiveActivityRecoveryStatus) -> Void)? {
        didSet { onRecoveryStatusChange?(recoveryStatus) }
    }

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
        latestState = state

        if activity == nil {
            guard lifecycleTask == nil else { return }
            guard Self.areActivitiesEnabled else { return }
            guard UIApplication.shared.applicationState == .active else { return }
            guard now.timeIntervalSince(lastRequestAt) >= Self.requestRetryInterval else { return }
            requestActivity(state: state,
                            leadingItem: leadingItem,
                            selectedMetric: selectedMetric,
                            at: now)
            return
        }

        guard forceUpdate
                || leadingItem != lastLeadingItem
                || selectedMetric != lastMetric
                || now.timeIntervalSince(lastUpdateEnqueuedAt) >= Self.updateInterval else { return }

        lastUpdateEnqueuedAt = now
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
        latestState = state
        beginRestart(state: state,
                     leadingItem: leadingItem,
                     selectedMetric: selectedMetric,
                     at: snapshot.date)
    }

    private func beginRestart(
        state: MiniWattsActivityAttributes.ContentState,
        leadingItem: LiveActivityLeadingItem,
        selectedMetric: LiveActivityMetric,
        at date: Date
    ) {
        // Keep the actual objects, not only their IDs. An Activity object can still
        // report `.active` after it has fallen out of `Activity.activities`; ending
        // only objects reacquired from the static list leaves that orphan alive
        // until the whole app process is restarted.
        let activitiesToEnd = allKnownActivities()

        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        lifecycleTask?.cancel()
        lifecycleTask = nil
        resetLocalActivity()
        recoveryStatus = .restarting

        lifecycleTask = Task { @MainActor [weak self] in
            for current in activitiesToEnd {
                await current.end(nil, dismissalPolicy: .immediate)
            }
            guard !Task.isCancelled,
                  let self,
                  self.lifecycleGeneration == generation else { return }

            // `end` returning does not mean the old presentation has released its
            // ActivityKit slot. Wait for the framework's source-of-truth list to
            // confirm release instead of relying on a fixed 400 ms delay.
            await self.waitForSystemRelease(of: Set(activitiesToEnd.map(\.id)))
            guard !Task.isCancelled,
                  self.lifecycleGeneration == generation else { return }

            await self.requestReplacement(
                state: state,
                leadingItem: leadingItem,
                selectedMetric: selectedMetric,
                at: date,
                generation: generation
            )
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
            case .active:
                needsReplacement = snapshot.date.timeIntervalSince(lastSuccessfulUpdateAt)
                    >= Self.staleInterval
            case .pending:
                needsReplacement = snapshot.date.timeIntervalSince(lastRequestAt)
                    >= Self.operationTimeoutSeconds
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
        let activitiesToEnd = allKnownActivities()
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        lifecycleTask?.cancel()
        lifecycleTask = nil
        resetLocalActivity()
        recoveryStatus = .idle
        guard !activitiesToEnd.isEmpty else { return }

        lifecycleTask = Task { @MainActor [weak self] in
            for current in activitiesToEnd {
                await current.end(nil, dismissalPolicy: .immediate)
            }
            guard !Task.isCancelled,
                  let self,
                  self.lifecycleGeneration == generation else { return }
            self.lifecycleTask = nil
        }
    }

    private func requestActivity(
        state: MiniWattsActivityAttributes.ContentState,
        leadingItem: LiveActivityLeadingItem,
        selectedMetric: LiveActivityMetric,
        at date: Date
    ) {
        guard Self.areActivitiesEnabled else { return }
        guard UIApplication.shared.applicationState == .active else { return }
        do {
            let requested = try Activity.request(
                attributes: MiniWattsActivityAttributes(startedAt: date),
                content: content(for: state, at: date),
                pushType: nil
            )
            adopt(requested)
            lastRequestAt = date
            lastUpdateEnqueuedAt = date
            lastSuccessfulUpdateAt = date
            lastLeadingItem = leadingItem
            lastMetric = selectedMetric
            schedulePendingStateTimeout(for: requested.id)
            recoveryStatus = .running
        } catch {
            // Live Activities can be disabled or the system-wide activity limit
            // can be full. Back off instead of repeating a failing system request
            // every sensor tick; the explicit restart button remains available.
            lastRequestAt = .now
            recoveryStatus = .failed(String(describing: error))
        }
    }

    private func allKnownActivities() -> [Activity<MiniWattsActivityAttributes>] {
        var activitiesByID: [String: Activity<MiniWattsActivityAttributes>] = [:]
        for current in Activity<MiniWattsActivityAttributes>.activities {
            activitiesByID[current.id] = current
        }
        if let activity {
            activitiesByID[activity.id] = activity
        }
        return Array(activitiesByID.values)
    }

    private func waitForSystemRelease(of activityIDs: Set<String>) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Self.systemReleaseTimeout)
        var trackedIDs = activityIDs
        var consecutiveEmptyChecks = 0

        while !Task.isCancelled {
            // Include every ongoing activity that appears during the drain. A
            // cancelled older restart may finish `Activity.request` just after the
            // first snapshot; three empty checks close that narrow race as well.
            let ongoingActivities = Activity<MiniWattsActivityAttributes>.activities.filter {
                Self.isOngoing($0.activityState)
            }
            trackedIDs.formUnion(ongoingActivities.map(\.id))
            let oldActivities = ongoingActivities.filter { trackedIDs.contains($0.id) }

            if oldActivities.isEmpty {
                consecutiveEmptyChecks += 1
                if consecutiveEmptyChecks >= 3 { return }
            } else {
                consecutiveEmptyChecks = 0
                for current in oldActivities {
                    await current.end(nil, dismissalPolicy: .immediate)
                }
            }
            if clock.now >= deadline {
                // Ask once more at the boundary. The later request loop backs off if
                // ActivityKit still hasn't released the system slot.
                for current in oldActivities {
                    await current.end(nil, dismissalPolicy: .immediate)
                }
                return
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    private func requestReplacement(
        state: MiniWattsActivityAttributes.ContentState,
        leadingItem: LiveActivityLeadingItem,
        selectedMetric: LiveActivityMetric,
        at date: Date,
        generation: Int
    ) async {
        var lastErrorDescription = "ActivityKit did not accept the request."

        for attempt in 0..<Self.replacementAttemptCount {
            guard !Task.isCancelled,
                  lifecycleGeneration == generation else { return }
            guard Self.areActivitiesEnabled else {
                recoveryStatus = .failed("Live Activities are disabled by the system.")
                return
            }
            guard UIApplication.shared.applicationState == .active else {
                recoveryStatus = .failed("MiniWatts left the foreground before restart completed.")
                return
            }

            do {
                let requested = try Activity.request(
                    attributes: MiniWattsActivityAttributes(startedAt: date),
                    content: content(for: state, at: .now),
                    pushType: nil
                )
                guard !Task.isCancelled, lifecycleGeneration == generation else {
                    await requested.end(nil, dismissalPolicy: .immediate)
                    return
                }
                adopt(requested)
                lastRequestAt = .now
                lastUpdateEnqueuedAt = .now
                lastSuccessfulUpdateAt = .now
                lastLeadingItem = leadingItem
                lastMetric = selectedMetric
                schedulePendingStateTimeout(for: requested.id)
                recoveryStatus = .running
                return
            } catch {
                lastErrorDescription = String(describing: error)
                lastRequestAt = .now
            }

            guard attempt + 1 < Self.replacementAttemptCount else { break }
            // A system slot that was released late is the common recoverable case.
            // Increasing delays avoid hammering ActivityKit while still healing in
            // the same app process, which the old fixed delay could not do.
            let delay = 400 * (attempt + 1)
            try? await Task.sleep(for: .milliseconds(delay))
        }

        guard !Task.isCancelled, lifecycleGeneration == generation else { return }
        recoveryStatus = .failed(lastErrorDescription)
    }

    private static func isOngoing(_ state: ActivityState) -> Bool {
        switch state {
        case .active, .stale, .pending: return true
        case .ended, .dismissed: return false
        @unknown default: return false
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
                    adopt(current)
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
            adopt(current)
            lastSuccessfulUpdateAt = current.content.state.sampledAt ?? .now
            lastUpdateEnqueuedAt = lastSuccessfulUpdateAt
            lastLeadingItem = nil
            lastMetric = nil
            recoveryStatus = .running
        }
    }

    private func adopt(_ activity: Activity<MiniWattsActivityAttributes>) {
        let changedActivity = self.activity?.id != activity.id
        self.activity = activity
        guard changedActivity || activityStateTask == nil else { return }
        observeStateUpdates(for: activity)
    }

    private func observeStateUpdates(for observed: Activity<MiniWattsActivityAttributes>) {
        activityStateTask?.cancel()
        let activityID = observed.id
        activityStateTask = Task { @MainActor [weak self] in
            for await state in observed.activityStateUpdates {
                guard !Task.isCancelled,
                      let self,
                      self.activity?.id == activityID else { return }
                switch state {
                case .active:
                    self.pendingStateTimeoutTask?.cancel()
                    self.pendingStateTimeoutTask = nil
                    self.recoveryStatus = .running
                case .stale:
                    // A stale activity can still accept an update. Foreground
                    // recovery uses the confirmed-update timestamp to decide
                    // whether it needs a complete replacement.
                    break
                case .ended, .dismissed:
                    self.resetLocalActivity()
                    self.recoveryStatus = .idle
                @unknown default:
                    if #available(iOS 26.0, *), state == .pending {
                        self.schedulePendingStateTimeout(for: activityID)
                    } else {
                        self.resetLocalActivity()
                    }
                }
            }
        }
    }

    private func schedulePendingStateTimeout(for activityID: String) {
        pendingStateTimeoutTask?.cancel()
        pendingStateTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.operationTimeout)
            guard !Task.isCancelled,
                  let self,
                  self.activity?.id == activityID,
                  UIApplication.shared.applicationState == .active,
                  let state = self.latestState else { return }
            if #available(iOS 26.0, *) {
                guard self.activity?.activityState == .pending else { return }
            } else {
                return
            }
            self.beginRestart(state: state,
                              leadingItem: self.lastLeadingItem ?? .statusIcon,
                              selectedMetric: self.lastMetric ?? .chargingPower,
                              at: .now)
        }
    }

    private func resetLocalActivity() {
        activity = nil
        lastRequestAt = .distantPast
        lastUpdateEnqueuedAt = .distantPast
        lastSuccessfulUpdateAt = .distantPast
        lastLeadingItem = nil
        lastMetric = nil
        pendingUpdate = nil
        updateGeneration &+= 1
        updateInFlight = false
        inFlightActivityID = nil
        updateTimeoutTask?.cancel()
        updateTimeoutTask = nil
        activityStateTask?.cancel()
        activityStateTask = nil
        pendingStateTimeoutTask?.cancel()
        pendingStateTimeoutTask = nil
    }

    private func beginUpdatingIfNeeded() {
        guard !updateInFlight,
              let content = pendingUpdate,
              let activity else { return }

        switch activity.activityState {
        case .active, .stale:
            break
        case .pending:
            schedulePendingStateTimeout(for: activity.id)
            return
        case .ended, .dismissed:
            resetLocalActivity()
            return
        @unknown default:
            resetLocalActivity()
            return
        }

        pendingUpdate = nil
        updateGeneration &+= 1
        let generation = updateGeneration
        let activityID = activity.id
        updateInFlight = true
        inFlightActivityID = activityID

        updateTimeoutTask?.cancel()
        updateTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.operationTimeout)
            guard !Task.isCancelled else { return }
            self?.finishUpdateAttempt(
                generation: generation,
                activityID: activityID,
                succeeded: false
            )
        }

        // Do not await this from the main-actor coalescer. If ActivityKit wedges,
        // the independent watchdog above is still able to replace the activity.
        Task.detached { [weak self] in
            guard let current = Activity<MiniWattsActivityAttributes>.activities
                .first(where: { $0.id == activityID }) else {
                await self?.finishUpdateAttempt(
                    generation: generation,
                    activityID: activityID,
                    succeeded: false
                )
                return
            }
            await current.update(content)
            await self?.finishUpdateAttempt(
                generation: generation,
                activityID: activityID,
                succeeded: true
            )
        }
    }

    private func finishUpdateAttempt(
        generation: Int,
        activityID: String,
        succeeded: Bool
    ) {
        guard updateGeneration == generation,
              updateInFlight,
              inFlightActivityID == activityID else { return }

        updateTimeoutTask?.cancel()
        updateTimeoutTask = nil
        updateInFlight = false
        inFlightActivityID = nil

        if succeeded {
            lastSuccessfulUpdateAt = .now
            if pendingUpdate != nil { beginUpdatingIfNeeded() }
            return
        }

        guard let state = latestState else {
            resetLocalActivity()
            return
        }
        beginRestart(state: state,
                     leadingItem: lastLeadingItem ?? .statusIcon,
                     selectedMetric: lastMetric ?? .chargingPower,
                     at: .now)
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
