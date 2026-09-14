import ActivityKit
import Foundation

/// Starts, feeds and ends the charging live activity.
///
/// Driven only by the app's own tick, so it only moves while the app runs. ActivityKit
/// will not start an activity from the background and there is no push channel (see
/// `ChargeActivityAttributes`). That shapes everything here:
/// - an activity is only ever started while the app is in front
/// - every update carries a stale date a little past the next expected update, so once
///   the app is suspended the Lock Screen marks the reading paused instead of passing
///   off an old number as live
/// - it ends when the charger comes out — which, if that happens while the app is
///   suspended, the app only learns on its next tick. The stale date covers the gap.
final class ChargeActivityController {
    private var activity: Activity<ChargeActivityAttributes>?
    private var adopted = false
    private var lastSent: ChargeReading?
    private var lastSentAt: Date = .distantPast
    private var lastStartAttempt: Date = .distantPast

    /// How long past an update its reading still counts as current. Updates go out
    /// every few seconds; this tolerates a couple of missed ones and no more.
    private static let staleAfter: TimeInterval = 45
    /// Minimum spacing between updates.
    private static let minimumInterval: TimeInterval = 5
    /// An update goes out at least this often, if only to push the stale date forward.
    private static let maximumInterval: TimeInterval = 20
    /// After a refused start — too many activities, the user switched them off —
    /// wait this long before trying again rather than asking every second.
    private static let retryInterval: TimeInterval = 30

    func sync(_ reading: ChargeReading, enabled: Bool, isForeground: Bool) {
        adoptExistingActivities()
        guard enabled else {
            end(with: reading, dismissal: .immediate)
            return
        }
        guard reading.externalConnected else {
            // Leave the final state up briefly: "unplugged at 86 %" is worth a glance.
            end(with: reading, dismissal: .after(reading.date.addingTimeInterval(120)))
            return
        }
        if let activity, activity.activityState == .active || activity.activityState == .stale {
            update(activity, with: reading)
        } else if isForeground {
            start(with: reading)
        }
    }

    /// An activity outlives the app being killed. The first sync after launch picks up
    /// one left behind and ends any others, rather than starting a duplicate.
    private func adoptExistingActivities() {
        guard !adopted else { return }
        adopted = true
        let existing = Activity<ChargeActivityAttributes>.activities
        activity = existing.first
        for id in existing.dropFirst().map(\.id) {
            Task { await Self.end(id, nil, dismissal: .immediate) }
        }
    }

    private func start(with reading: ChargeReading) {
        guard reading.date.timeIntervalSince(lastStartAttempt) >= Self.retryInterval,
              ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        lastStartAttempt = reading.date
        do {
            activity = try Activity.request(
                attributes: ChargeActivityAttributes(startedAt: reading.date, startPercent: reading.percent),
                content: content(for: reading),
                pushType: nil)
            lastSent = reading
            lastSentAt = reading.date
        } catch {
            // Refused: not frontmost after all, activities disabled, or the system
            // limit reached. Tried again after `retryInterval`.
        }
    }

    private func update(_ activity: Activity<ChargeActivityAttributes>, with reading: ChargeReading) {
        let elapsed = reading.date.timeIntervalSince(lastSentAt)
        guard elapsed >= Self.minimumInterval else { return }
        if elapsed < Self.maximumInterval, let lastSent, !Self.differs(lastSent, reading) { return }
        lastSent = reading
        lastSentAt = reading.date
        let content = content(for: reading)
        let id = activity.id
        Task { await Self.update(id, content) }
    }

    private func end(with reading: ChargeReading, dismissal: ActivityUIDismissalPolicy) {
        guard let activity else { return }
        self.activity = nil
        lastSent = nil
        lastSentAt = .distantPast
        let final = ActivityContent(state: reading, staleDate: nil)
        let id = activity.id
        Task { await Self.end(id, final, dismissal: dismissal) }
    }

    // `Activity` is not `Sendable`, and its `update` and `end` are nonisolated async.
    // Calling them on an instance that lives on the main actor — held in a property, or
    // just looked up from main-actor code — sends it off the actor, and Swift 6 refuses
    // to compile that. So the lookup and the call happen together off the actor: only an
    // id and the content, which are both `Sendable`, cross over.

    @concurrent
    nonisolated private static func update(_ id: String,
                                           _ content: ActivityContent<ChargeReading>) async {
        await activity(id)?.update(content)
    }

    @concurrent
    nonisolated private static func end(_ id: String,
                                        _ content: ActivityContent<ChargeReading>?,
                                        dismissal: ActivityUIDismissalPolicy) async {
        await activity(id)?.end(content, dismissalPolicy: dismissal)
    }

    nonisolated private static func activity(_ id: String) -> Activity<ChargeActivityAttributes>? {
        Activity<ChargeActivityAttributes>.activities.first { $0.id == id }
    }

    private func content(for reading: ChargeReading) -> ActivityContent<ChargeReading> {
        ActivityContent(state: reading, staleDate: reading.date.addingTimeInterval(Self.staleAfter))
    }

    /// Whether a reading has moved enough to be worth an update on its own.
    private static func differs(_ old: ChargeReading, _ new: ChargeReading) -> Bool {
        old.percent != new.percent
            || old.source != new.source
            || old.isCharging != new.isCharging
            || old.isOnHold != new.isOnHold
            || old.isFull != new.isFull
            || abs((old.watts ?? -1) - (new.watts ?? -1)) >= 0.2
            || abs((old.batteryTemperature ?? 0) - (new.batteryTemperature ?? 0)) >= 0.5
    }
}
