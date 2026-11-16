/// AVKit may temporarily suspend PiP or report a transition after the app has
/// returned to the foreground. Neither is proof that the session was stopped.
nonisolated enum PictureInPictureReconciliationPolicy {
    enum ForegroundAction: Equatable {
        case wait, completeStart, failOrphanedStart, adoptActive, checkStopped
    }

    static func foreground(isStarting: Bool, startTaskExists: Bool,
                           localActive: Bool, systemActive: Bool,
                           systemSuspended: Bool) -> ForegroundAction {
        if isStarting {
            if systemActive { return .completeStart }
            if startTaskExists || systemSuspended { return .wait }
            return .failOrphanedStart
        }
        if systemSuspended { return .wait }
        if systemActive && !localActive { return .adoptActive }
        if !systemActive && localActive { return .checkStopped }
        return .wait
    }

    static func shouldRecoverStopped(localActive: Bool, isStarting: Bool,
                                     isStopping: Bool, systemActive: Bool,
                                     systemSuspended: Bool) -> Bool {
        localActive && !isStarting && !isStopping && !systemActive && !systemSuspended
    }
}
