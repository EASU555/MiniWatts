import Foundation
import UIKit

/// Reads the percentage that iOS itself publishes instead of estimating it from
/// voltage or battery energy.
///
/// `UIDevice.batteryLevel` is intentionally coarse on iPhone and can sit on one
/// five-point bucket while the status bar moves through several one-percent
/// values. MiniWatts therefore asks the same system services used by iOS first,
/// while keeping the public UIKit value as the final fallback.
final class SystemBatteryLevelReader {
    enum Source: String {
        case mobileGestalt = "MobileGestalt"
        case powerSource = "powerd"
        case uiDevice = "UIDevice"
    }

    struct Reading: Equatable {
        let percent: Int
        let source: Source
        let mobileGestaltPercent: Int?
        let powerSourcePercent: Int?
        let uiDevicePercent: Int?
        let sampledAt: Date
    }

    private typealias CopyAnswerFunction =
        @convention(c) (CFString) -> Unmanaged<CFTypeRef>?

    var onSystemChange: (() -> Void)?

    private let mobileGestaltHandle: UnsafeMutableRawPointer?
    private let copyAnswer: CopyAnswerFunction?
    private var notificationTokens: [NSObjectProtocol] = []

    init() {
        let handle = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_LAZY)
        mobileGestaltHandle = handle
        copyAnswer = handle
            .flatMap { dlsym($0, "MGCopyAnswer") }
            .map { unsafeBitCast($0, to: CopyAnswerFunction.self) }

        UIDevice.current.isBatteryMonitoringEnabled = true
        let center = NotificationCenter.default
        for name in [UIDevice.batteryLevelDidChangeNotification,
                     UIDevice.batteryStateDidChangeNotification] {
            notificationTokens.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.onSystemChange?() }
                }
            )
        }
    }

    /// Re-establishes UIKit monitoring after foreground transitions. Some iOS 27
    /// builds leave `batteryLevel` on the value captured when the app launched.
    /// The precise system-service reads below do not depend on this, but UIKit is
    /// kept healthy as a fallback and as a useful diagnostic comparison.
    func prepareForForeground() {
        if !UIDevice.current.isBatteryMonitoringEnabled {
            UIDevice.current.isBatteryMonitoringEnabled = true
        }
    }

    func read(powerSource: [String: Any]?, at date: Date = .now) -> Reading? {
        let gestalt = mobileGestaltPercent()
        let powerd = Self.validPercent(Self.integer(powerSource?["Current Capacity"]))
        let uiDevice = Self.uiDevicePercent()

        let selected: (Int, Source)?
        if let gestalt {
            selected = (gestalt, .mobileGestalt)
        } else if let powerd {
            selected = (powerd, .powerSource)
        } else if let uiDevice {
            selected = (uiDevice, .uiDevice)
        } else {
            selected = nil
        }

        guard let selected else { return nil }
        return Reading(percent: selected.0,
                       source: selected.1,
                       mobileGestaltPercent: gestalt,
                       powerSourcePercent: powerd,
                       uiDevicePercent: uiDevice,
                       sampledAt: date)
    }

    private func mobileGestaltPercent() -> Int? {
        guard let answer = copyAnswer?("BatteryCurrentCapacity" as CFString)?.takeRetainedValue()
        else { return nil }
        return Self.validPercent(Self.integer(answer))
    }

    private static func uiDevicePercent() -> Int? {
        let level = UIDevice.current.batteryLevel
        guard level >= 0 else { return nil }
        return validPercent(Int((Double(level) * 100).rounded()))
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let number = value as? Int { return number }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private static func validPercent(_ value: Int?) -> Int? {
        guard let value, (0...100).contains(value) else { return nil }
        return value
    }
}
