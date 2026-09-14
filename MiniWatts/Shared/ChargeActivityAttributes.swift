import ActivityKit
import Foundation

/// The live activity shown on the Lock Screen, in the Dynamic Island and in StandBy
/// while a charger is connected.
///
/// Compiled into both targets: the app starts and updates the activity, the widget
/// extension renders it. ActivityKit matches the two by this type.
///
/// It is only ever updated by the app, while the app is running. Nothing pushes to
/// it from outside — push updates need an APNs server and a certificate tied to a
/// developer team, and a sideloaded copy re-signed with someone else's Apple ID
/// would never receive them. So every update carries a stale date, and the
/// extension says the reading is out of date rather than showing an old number as
/// if it were current.
nonisolated struct ChargeActivityAttributes: ActivityAttributes {
    typealias ContentState = ChargeReading

    /// When the charger was connected.
    var startedAt: Date
    var startPercent: Int?
}
