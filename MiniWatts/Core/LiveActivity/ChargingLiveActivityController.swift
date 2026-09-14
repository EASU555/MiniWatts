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

    init() {
        activity = Activity<MiniWattsActivityAttributes>.activities.first
    }

    static var areActivitiesEnabled: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    var isRunning: Bool { activity != nil }

    func reconcile(snapshot: PowerSnapshot,
                   selectedMetric: LiveActivityMetric,
                   enabled: Bool,
                   forceUpdate: Bool = false) {
        guard enabled else {
            endIfNeeded()
            return
        }

        if let activity,
           activity.activityState == .ended || activity.activityState == .dismissed {
            self.activity = nil
            lastUpdate = .distantPast
            lastMetric = nil
        }

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
                // can be full. The monitor must keep sampling even when this surface
                // is unavailable, so a failed request is intentionally non-fatal.
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
            ?? Activity<MiniWattsActivityAttributes>.activities.first
        guard let active else { return }
        activity = nil
        lastUpdate = .distantPast
        lastMetric = nil
        pendingUpdate = nil
        updateTask?.cancel()
        updateTask = nil
        Task {
            await active.end(nil, dismissalPolicy: .immediate)
        }
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
                await activity.update(content)
            case .pending:
                // Keep the latest value ready until the system finishes presenting
                // the newly requested activity.
                pendingUpdate = content
                try? await Task.sleep(for: .milliseconds(250))
            case .ended, .dismissed:
                self.activity = nil
                lastUpdate = .distantPast
                lastMetric = nil
                pendingUpdate = nil
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
