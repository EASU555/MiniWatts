import Foundation

/// An explicit sandbox denial will not acquire a new entitlement during this
/// process. Do not make the same privileged request every second after it fails.
/// Transient failures still retry, and a new process starts with no cached denial.
nonisolated enum ChargeStatusReadPolicy {
    static let notPrivileged = Int32(bitPattern: 0xe00002c1)

    static func shouldRetry(after result: Int32) -> Bool {
        result != notPrivileged
    }
}
