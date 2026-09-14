import ActivityKit
import Foundation

/// Owns the charging Live Activity without leaking ActivityKit into the sensor model.
/// Sensor reads normally stop when the app is suspended (a running floating PiP is
/// the exception), so every update carries a short `staleDate`; WidgetKit can then
/// label the last value as paused instead of pretending it is still live.
@MainActor
final class ChargingLiveActivityController {
    private static let updateInterval: TimeInterval = 5
    private static let staleInterval: TimeInterval = 15

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
        guard enabled, snapshot.externalConnected else {
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
        let measuredInput = snapshot.inputWatts
        let batterySide = snapshot.batteryWatts.map { max($0, 0) }
        return MiniWattsActivityAttributes.ContentState(
            chargeWatts: measuredInput ?? batterySide,
            powerIsBatterySide: measuredInput == nil,
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
