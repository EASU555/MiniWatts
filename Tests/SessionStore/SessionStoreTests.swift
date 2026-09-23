import Foundation

// The persistence test compiles just the session model, not the sensor engine.
nonisolated struct EnergyTotals: Codable, Hashable, Sendable {}

@main struct SessionStoreTests {
    static func save(_ store: SessionStore, _ sessions: [ChargeSession]) async -> SessionStore.SaveResult {
        await withCheckedContinuation { continuation in
            store.save(sessions) { continuation.resume(returning: $0) }
        }
    }

    static func checkSaved(_ result: SessionStore.SaveResult) {
        guard case .saved = result else { preconditionFailure("Expected both history copies to save") }
    }

    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(directory: root)
        guard case .loaded(let first) = await store.loaded(), first.isEmpty else {
            preconditionFailure("First launch should have empty history")
        }

        let charge = ChargeSession(start: .now, startPercent: 42,
                                   adapterName: "test", adapterRatedWatts: 25,
                                   isWireless: false)
        checkSaved(await save(store, [charge]))
        let primary = root.appendingPathComponent("charge-sessions.json")
        let backup = root.appendingPathComponent("charge-sessions.json.backup")
        let primaryBytes = try Data(contentsOf: primary)
        let backupBytes = try Data(contentsOf: backup)
        precondition(primaryBytes == backupBytes,
                     "Primary and backup diverged after a successful write")

        try Data("damaged primary".utf8).write(to: primary, options: .atomic)
        guard case .recovered(let recovered, _) = await store.loaded(),
              recovered.map(\.id) == [charge.id] else {
            preconditionFailure("A damaged primary should recover from the valid backup")
        }
        print("PASS: damaged primary recovers from the safety copy")

        try Data("damaged backup".utf8).write(to: backup, options: .atomic)
        guard case .failed = await store.loaded() else {
            preconditionFailure("Two damaged files must never be reported as empty history")
        }
        let damagedBytes = try Data(contentsOf: primary)
        precondition(damagedBytes == Data("damaged primary".utf8),
                     "A failed load unexpectedly changed the original file")
        print("PASS: two damaged copies report failure without erasing evidence")

        checkSaved(await save(store, []))
        guard case .loaded(let cleared) = await store.loaded(), cleared.isEmpty else {
            preconditionFailure("An explicit delete must not resurrect the previous backup")
        }
        print("PASS: explicit clear replaces both history copies")

        let blocker = root.appendingPathComponent("blocked")
        try Data("not a directory".utf8).write(to: blocker)
        let blockedStore = SessionStore(directory: blocker)
        guard case .failed = await save(blockedStore, [charge]) else {
            preconditionFailure("A failed primary write must reach the caller")
        }

        let partial = root.appendingPathComponent("partial")
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: partial.appendingPathComponent("charge-sessions.json.backup"),
            withIntermediateDirectories: true
        )
        let partialStore = SessionStore(directory: partial)
        guard case .backupFailed = await save(partialStore, [charge]) else {
            preconditionFailure("A failed safety-copy write must be distinguishable")
        }
        guard case .loaded(let primaryOnly) = await partialStore.loaded(),
              primaryOnly.map(\.id) == [charge.id] else {
            preconditionFailure("A valid primary should remain readable after backup failure")
        }
        print("PASS: primary and backup write failures are reported separately")
    }
}
