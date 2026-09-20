// Test-only application state; no iPhone UI is simulated by these tests.
@MainActor public final class UIApplication {
    public enum State { case active, inactive, background }
    public static let shared = UIApplication()
    public var applicationState = State.active
}
