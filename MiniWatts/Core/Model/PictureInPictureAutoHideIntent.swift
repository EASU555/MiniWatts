/// Tracks a single post-start hide request. A manual action, stop, replacement,
/// or activity recovery invalidates its token so an old delayed task cannot hide
/// a window that the user has since restored.
nonisolated struct PictureInPictureAutoHideIntent {
    private var generation = 0
    private(set) var pendingToken: Int?

    init() {}

    var isPending: Bool { pendingToken != nil }

    mutating func schedule(enabled: Bool, isHiddenMode: Bool, preservingRecovery: Bool) -> Int? {
        cancel()
        guard enabled, isHiddenMode, !preservingRecovery else { return nil }
        pendingToken = generation
        return generation
    }

    mutating func cancel() {
        generation &+= 1
        pendingToken = nil
    }

    mutating func consume(_ token: Int) -> Bool {
        guard pendingToken == token else { return false }
        pendingToken = nil
        return true
    }
}
