import ActivityKit
import Foundation

/// Owns the charging Live Activity without leaking ActivityKit into the sensor model.
/// A manually enabled activity owns a local background-refresh session until the
/// user turns it off. Every update still carries a short `staleDate`, so WidgetKit
/// clearly marks the value as paused if iOS interrupts that session.
@MainActor
final class ChargingLiveActivityController {
    private static let updateInterval: TimeInterval = 1
    private static let staleInterval: TimeInterval = 4

    private var activity: Activity<MiniWattsActivityAttributes>?
    private var lastUpdate = Date.distantPast
    private var lastMetric: LiveActivityMetric?

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
        let update = content(for: state, at: now)
        guard let activity else { return }
        let activityID = activity.id
        Task.detached {
            guard let current = Activity<MiniWattsActivityAttributes>.activities
                .first(where: { $0.id == activityID }) else { return }
            await current.update(update)
        }
    }

    func endIfNeeded() {
        let active = activity
            ?? Activity<MiniWattsActivityAttributes>.activities.first
        guard let active else { return }
        activity = nil
        lastUpdate = .distantPast
        lastMetric = nil
        let activityID = active.id
        Task.detached {
            guard let current = Activity<MiniWattsActivityAttributes>.activities
                .first(where: { $0.id == activityID }) else { return }
            await current.end(nil, dismissalPolicy: .immediate)
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
