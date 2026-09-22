import Foundation
import ActivityKit
import UIKit

// Only the sensor input is stubbed. Tests compile the real controller unchanged.
struct PowerSnapshot {
    var date = Date.now
    var externalConnected = true
    var chargingPower: (watts: Double?, isBatterySide: Bool) = (12, false)
    var batteryWatts: Double? = 10
    var percent: Int? = 50
    var cpuUsagePercent: Double? = 24
    var socTemperature: Double? = 32
    var batteryTemperature: Double? = 30
    var hottestSensor: (value: Double, name: String)? = nil
    var isWirelessInput = false
}

@main @MainActor struct RecoveryTests {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }
    static func tick(_ controller: ChargingLiveActivityController,
                     enabled: Bool = true,
                     minimalMetric: LiveActivityMetric = .chargingPower) {
        controller.reconcile(snapshot: PowerSnapshot(), leadingItem: .statusIcon,
                             selectedMetric: .chargingPower, minimalMetric: minimalMetric,
                             enabled: enabled, forceUpdate: true)
    }
    static func restart(_ controller: ChargingLiveActivityController) {
        controller.restart(snapshot: PowerSnapshot(), leadingItem: .statusIcon,
                           selectedMetric: .chargingPower, minimalMetric: .chargingPower)
    }
    static func sample(_ controller: ChargingLiveActivityController, seconds: Double) async {
        let until = ContinuousClock.now.advanced(by: .milliseconds(Int(seconds * 1000)))
        while ContinuousClock.now < until {
            tick(controller)
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
    static func main() async {
        // A pending request used to have its 8 s deadline reset by every tick.
        TestSystem.reset()
        TestSystem.configure(pending: true)
        let pending = ChargingLiveActivityController()
        tick(pending)
        await sample(pending, seconds: 9.5)
        check(TestSystem.requests >= 2, "Pending deadline was postponed by sampling")
        check(TestSystem.requests <= 3, "Recovery is creating an activity storm")
        pending.endIfNeeded()
        try? await Task.sleep(for: .milliseconds(300))
        print("PASS: pending deadline fires while samples continue")

        // Simulate a system end that outlasts the entire restart deadline.
        TestSystem.reset()
        let hung = ChargingLiveActivityController()
        tick(hung)
        try? await Task.sleep(for: .milliseconds(100))
        let oldID = Activity<MiniWattsActivityAttributes>.activities.first!.id
        TestSystem.configure(endDelay: .seconds(12))
        restart(hung)
        await sample(hung, seconds: 6)
        check(TestSystem.requests == 2, "A stuck end blocked replacement indefinitely")
        check(hung.recoveryStatus == .running, "Restart button remained stuck")
        check(!TestSystem.updates.contains(oldID), "Sampling re-adopted the retiring activity")
        check(TestSystem.endings.filter { $0 == oldID }.count == 1,
              "Duplicate end workers were launched for a stuck activity")
        // The old end finishes late, after a replacement is already running.
        await sample(hung, seconds: 7)
        check(hung.isRunning, "Late cleanup removed the new activity")
        check(TestSystem.requests == 2, "Late cleanup forced another replacement")
        TestSystem.configure()
        hung.endIfNeeded()
        try? await Task.sleep(for: .milliseconds(300))
        print("PASS: hung end is bounded, ticks cannot resurrect old activity, late cleanup is scoped")

        // Background update timeout must never end the only visible activity.
        TestSystem.reset()
        let background = ChargingLiveActivityController()
        tick(background)
        try? await Task.sleep(for: .milliseconds(100))
        TestSystem.configure(updateDelay: .seconds(12))
        UIApplication.shared.applicationState = .background
        await sample(background, seconds: 9)
        check(TestSystem.endings.isEmpty, "Background timeout destroyed the current activity")
        check(TestSystem.requests == 1, "Background timeout tried to create an activity")
        UIApplication.shared.applicationState = .active
        TestSystem.configure()
        background.recoverAfterEnteringForeground(snapshot: PowerSnapshot(),
                                                   leadingItem: .statusIcon,
                                                   selectedMetric: .chargingPower,
                                                   minimalMetric: .chargingPower)
        await sample(background, seconds: 1)
        check(TestSystem.requests == 2, "Foreground recovery did not replace failed pipeline")
        background.endIfNeeded()
        await sample(background, seconds: 0) // keep the explicit stop as the last action
        try? await Task.sleep(for: .milliseconds(300))
        check(!background.isRunning, "Explicit stop left an activity in the controller")
        print("PASS: background timeout preserves activity and foreground repairs it")

        TestSystem.reset()
        let delayed = ChargingLiveActivityController()
        tick(delayed)
        try? await Task.sleep(for: .milliseconds(100))
        TestSystem.configure(updateDelay: .seconds(10))
        UIApplication.shared.applicationState = .background
        await sample(delayed, seconds: 9)
        TestSystem.configure()
        await sample(delayed, seconds: 2)
        check(TestSystem.requests == 1 && TestSystem.endings.isEmpty,
              "A slow background update unnecessarily replaced the activity")
        check(TestSystem.updates.count > 1, "Late successful update did not resume sampling")
        UIApplication.shared.applicationState = .active
        delayed.endIfNeeded()
        try? await Task.sleep(for: .milliseconds(300))
        print("PASS: late successful background update resumes without reopening app")

        TestSystem.reset()
        let toggled = ChargingLiveActivityController()
        tick(toggled)
        TestSystem.configure(endDelay: .seconds(2))
        toggled.endIfNeeded()
        for _ in 0..<5 { tick(toggled, enabled: false) }
        restart(toggled)
        await sample(toggled, seconds: 3)
        check(TestSystem.requests == 2, "Off/on sequence failed to create a replacement")
        check(toggled.isRunning, "Old stop operation removed the replacement")
        TestSystem.configure()
        toggled.endIfNeeded()
        print("PASS: rapid off/on and repeated disabled ticks")

        // Changing the minimal readout must update the existing activity, not
        // create a second activity that competes for an iPhone 18 Pro's slots.
        TestSystem.reset()
        check(LiveActivityMinimalSelection.followRightSide.resolvedMetric(primary: .socTemperature)
              == .socTemperature, "Follow-right selection did not resolve")
        let minimal = ChargingLiveActivityController()
        tick(minimal)
        try? await Task.sleep(for: .milliseconds(100))
        guard let active = Activity<MiniWattsActivityAttributes>.activities.first else {
            fatalError("Minimal metric test did not start an activity")
        }
        tick(minimal, minimalMetric: .batteryTemperature)
        try? await Task.sleep(for: .milliseconds(150))
        check(active.content.state.minimalMetric == .batteryTemperature,
              "Minimal metric change did not reach ActivityKit")
        check(TestSystem.requests == 1, "Minimal metric change created another activity")
        minimal.endIfNeeded()
        print("PASS: minimal readout selection updates the existing activity")

        // Changing the relevance hint must update the same ActivityContent in
        // place. Placement is iOS-owned, so only the submitted hint is testable.
        TestSystem.reset()
        let priority = ChargingLiveActivityController()
        tick(priority)
        try? await Task.sleep(for: .milliseconds(100))
        guard let priorityActivity = Activity<MiniWattsActivityAttributes>.activities.first else {
            fatalError("Priority test did not start an activity")
        }
        check(priorityActivity.content.relevanceScore == 1, "Default relevance changed")
        priority.setRelevanceScore(0)
        tick(priority)
        try? await Task.sleep(for: .milliseconds(150))
        check(priorityActivity.content.relevanceScore == 0, "Lower relevance did not reach ActivityKit")
        check(TestSystem.requests == 1, "Changing relevance restarted the activity")
        priority.setRelevanceScore(1)
        tick(priority)
        try? await Task.sleep(for: .milliseconds(150))
        check(priorityActivity.content.relevanceScore == 1, "Higher relevance did not reach ActivityKit")
        priority.endIfNeeded()
        print("PASS: relevance switches between 0 and 1 on the existing activity")
    }
}
