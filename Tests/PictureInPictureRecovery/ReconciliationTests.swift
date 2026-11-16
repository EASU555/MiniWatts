import Foundation

@main struct ReconciliationTests {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }

    static func main() {
        typealias Policy = PictureInPictureReconciliationPolicy
        check(Policy.foreground(isStarting: true, startTaskExists: true,
                                localActive: false, systemActive: false,
                                systemSuspended: false) == .wait,
              "A pending AVKit start was failed on foreground return")
        check(Policy.foreground(isStarting: true, startTaskExists: false,
                                localActive: false, systemActive: false,
                                systemSuspended: false) == .failOrphanedStart,
              "An orphaned start was left spinning")
        check(Policy.foreground(isStarting: true, startTaskExists: true,
                                localActive: false, systemActive: true,
                                systemSuspended: false) == .completeStart,
              "An accepted start was not completed")
        check(Policy.foreground(isStarting: false, startTaskExists: false,
                                localActive: true, systemActive: false,
                                systemSuspended: true) == .wait,
              "A suspended session was mistaken for a stop")
        check(Policy.foreground(isStarting: false, startTaskExists: false,
                                localActive: false, systemActive: true,
                                systemSuspended: false) == .adoptActive,
              "An already active system session was not adopted")
        check(!Policy.shouldRecoverStopped(localActive: true, isStarting: false, isStopping: false,
                                           systemActive: true, systemSuspended: false),
              "A stale inactive callback tore down an active session")
        check(!Policy.shouldRecoverStopped(localActive: true, isStarting: false, isStopping: false,
                                           systemActive: false, systemSuspended: true),
              "A system-suspended session was torn down")
        check(!Policy.shouldRecoverStopped(localActive: true, isStarting: false, isStopping: true,
                                           systemActive: false, systemSuspended: false),
              "An explicit stop was replaced by unexpected-stop recovery")
        check(Policy.shouldRecoverStopped(localActive: true, isStarting: false, isStopping: false,
                                          systemActive: false, systemSuspended: false),
              "A confirmed vanished session was not recovered")
        print("PASS: pending starts, stale callbacks, suspension and confirmed PiP stops")
    }
}
