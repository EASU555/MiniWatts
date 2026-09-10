import Foundation
import ObjectiveC

/// One battery-powered device the system knows about: the phone itself, a paired
/// Watch, one earbud or the case of a pair of AirPods, a MagSafe battery pack.
///
/// Shapes here follow the real `BCBatteryDevice` interface rather than guesswork.
/// See `Batsie` (github.com/leptos-null/Batsie), which carries a cleaned-up header
/// and — importantly — is an ordinary sandboxed app, not a tweak.
nonisolated struct ExternalBatteryDevice: Identifiable, Hashable {
    /// `BCBatteryDeviceAccessoryCategory`, iOS 11.4+.
    enum Category: Int {
        case unknown, speaker, headphone, watch, batteryCase, keyboard, trackpad, pencil
    }

    /// `BCBatteryDeviceTransportType`: 1 internal, 2 wired (serial/USB/AID),
    /// 3 wireless (Bluetooth, BLE, inductive in-band).
    enum Transport: Int {
        case internalPower = 1, wired = 2, wireless = 3

        var title: LocalizedStringResource {
            switch self {
            case .internalPower: return "Internal"
            case .wired: return "Wired"
            case .wireless: return "Wireless"
            }
        }
    }

    let id: String
    let name: String
    /// `groupName`: the pieces of one pair of AirPods share it.
    let groupName: String?
    let category: Category
    let vendor: String?
    /// 0…100. `percentCharge` is an `NSInteger` percentage, not a fraction.
    let percent: Int?
    let isCharging: Bool
    let isConnected: Bool
    let isInternal: Bool
    let isLowBattery: Bool
    /// `approximatesPercentCharge`: the accessory reports a coarse level, which is
    /// why the system widget shows "~" in front of it for some devices.
    let isApproximate: Bool
    /// `BCBatteryDevicePart`, a bitmask: Left 1, Right 2, Case 4. Zero for an
    /// accessory that is not in pieces. Kept as the raw mask rather than as a
    /// pre-rendered "Left" so that no English reaches the model layer — the
    /// translated form is `partTitle`.
    let parts: Int
    let transport: Transport?
    /// Everything the object would hand over, for the debug view.
    let raw: [String: String]

    /// Which piece of a multi-part accessory this is, translated. Nil when the
    /// accessory is a single unit.
    var partTitle: LocalizedStringResource? {
        switch parts {
        case 1: return "Left"
        case 2: return "Right"
        case 4: return "Case"
        case 3: return "Left + Right"
        case 0: return nil
        default: return "Earbuds + Case"
        }
    }

    var symbol: String {
        if isInternal { return "iphone" }
        switch category {
        case .watch: return "applewatch"
        case .headphone: return name.localizedCaseInsensitiveContains("airpods") ? "airpods" : "headphones"
        case .speaker: return "hifispeaker"
        case .batteryCase: return "battery.100.bolt"
        case .keyboard: return "keyboard"
        case .trackpad: return "magictrackpad"
        case .pencil: return "applepencil"
        case .unknown: break
        }
        let n = name.lowercased()
        if n.contains("watch") { return "applewatch" }
        if n.contains("airpods") { return "airpods" }
        if n.contains("battery") || n.contains("magsafe") { return "battery.100.bolt" }
        return "battery.100"
    }
}

/// Bridge to `BatteryCenter.framework`, the private framework behind the system
/// Batteries widget. It loads from an ordinary sandbox and needs no entitlement,
/// but it is private API and can change or vanish in any iOS release —
/// every call here is defensive, and every failure is reported with the step that
/// failed rather than as a bare empty list.
nonisolated final class BatteryCenterBridge {
    /// Where the bridge got to. The UI shows this verbatim, because "no devices"
    /// and "the framework would not load" look identical otherwise, and only the
    /// first of those is worth reporting as a bug.
    enum Status: Equatable {
        case ready
        case frameworkMissing(String)
        case controllerClassMissing
        case controllerUnavailable
        case deviceListMissing
        case empty

        /// For the Devices screen: what it means, in the app's own voice.
        ///
        /// Every failure reads the same from outside, `.empty` included. That case used
        /// to say "No accessories connected. Pair a Watch, AirPods or a MagSafe battery
        /// and they appear here" — which is untrue on current iOS, where an empty list
        /// is also what comes back with a Watch on your wrist, and is indistinguishable
        /// from an honest one. Which step failed is a question for Raw data; see
        /// `diagnostic`.
        var userMessage: LocalizedStringResource? {
            switch self {
            case .ready: return nil
            case .empty, .frameworkMissing, .controllerClassMissing,
                 .controllerUnavailable, .deviceListMissing:
                return "Accessory battery levels aren't available on this version of iOS."
            }
        }

        /// For Raw data: which step failed, in enough detail to act on.
        var diagnostic: LocalizedStringResource? {
            switch self {
            case .ready: return nil
            case .frameworkMissing(let reason):
                return "BatteryCenter.framework did not load: \(reason)"
            case .controllerClassMissing:
                return "BatteryCenter loaded but BCBatteryDeviceController is not in the runtime."
            case .controllerUnavailable:
                return "BCBatteryDeviceController could not be created on this iOS version."
            case .deviceListMissing:
                return "BCBatteryDeviceController exposes no device list on this iOS version."
            case .empty:
                return "BatteryCenter loaded and answered, but reported no connected devices. Its XPC to powerd is denied: the console shows _BCPowerSourceController \"Failed to obtain power sources info\"."
            }
        }
    }

    private(set) var status: Status
    /// Which accessor produced the controller, for the diagnostics line.
    private(set) var controllerOrigin = "none"
    private let controller: NSObject?
    /// Held for the life of the bridge: the controller keeps only a weak reference.
    private let observer = DeviceObserver()

    init() {
        // Loaded as a bundle rather than with `dlopen`, which only ever answers
        // NULL: `NSBundle` hands back an NSError saying why. The DYLD_ROOT_PATH
        // prefix is what makes the same code work in the simulator, whose system
        // frameworks live under the runtime root rather than at "/". Both details
        // are lifted from Batsie.
        let root = ProcessInfo.processInfo.environment["DYLD_ROOT_PATH"] ?? ""
        let path = root + "/System/Library/PrivateFrameworks/BatteryCenter.framework"
        guard let bundle = Bundle(path: path) else {
            status = .frameworkMissing("no bundle at \(path)")
            controller = nil
            return
        }
        do {
            try bundle.loadAndReturnError()
        } catch {
            status = .frameworkMissing(error.localizedDescription)
            controller = nil
            return
        }
        guard let controllerClass = NSClassFromString("BCBatteryDeviceController") else {
            status = .controllerClassMissing
            controller = nil
            return
        }
        guard let (instance, origin) = Self.makeController(controllerClass) else {
            status = .controllerUnavailable
            controller = nil
            return
        }
        controller = instance
        controllerOrigin = origin
        status = .ready
        beginObserving(instance)
    }

    /// iOS 9 through the mid-teens exposed `+sharedInstance`. Current releases do
    /// not — the selector is not even present in the framework binary — and the
    /// controller is an ordinary object you allocate. Both are tried, newest
    /// arrangement last, so this keeps working on whichever the phone has.
    private static func makeController(_ cls: AnyClass) -> (NSObject, String)? {
        let shared = NSSelectorFromString("sharedInstance")
        if class_getClassMethod(cls, shared) != nil,
           let instance = (cls as AnyObject).perform(shared)?.takeUnretainedValue() as? NSObject {
            return (instance, "sharedInstance")
        }
        // `+new` follows the create rule, so the +1 is handed to ARC correctly.
        guard let instance = (cls as AnyObject)
            .perform(NSSelectorFromString("new"))?.takeRetainedValue() as? NSObject else { return nil }
        return (instance, "new")
    }

    /// Registering an observer is what starts collection.
    ///
    /// The controller has `_beginPowerSourceObservingIfNecessary` and calls it when
    /// an observer is added, so a freshly allocated controller that nobody is
    /// watching can legitimately report an empty `connectedDevices` forever. The
    /// callback body is deliberately empty — `PowerMonitor` polls — but the
    /// registration has to exist.
    private func beginObserving(_ controller: NSObject) {
        let selector = NSSelectorFromString("addBatteryDeviceObserver:queue:")
        guard controller.responds(to: selector) else { return }
        controller.perform(selector, with: observer, with: DispatchQueue.main)
    }

    /// The devices BatteryCenter currently reports, one entry per `BCBatteryDevice`.
    /// A pair of AirPods arrives as several entries sharing a `groupName`.
    func read() -> [ExternalBatteryDevice] {
        guard let controller else { return [] }
        guard let key = ["connectedDevices", "devices"].first(where: {
            controller.responds(to: NSSelectorFromString($0))
        }), let list = controller.value(forKey: key) as? [NSObject] else {
            status = .deviceListMissing
            return []
        }
        status = list.isEmpty ? .empty : .ready
        return list.map(device(from:))
    }

    // MARK: - Object reading

    private func device(from object: NSObject) -> ExternalBatteryDevice {
        let raw = Self.readableProperties(of: object)
        let name = Self.string(object, "name")
            ?? Self.string(object, "groupName")
            ?? String(localized: "Unknown device")
        let identifier = Self.string(object, "identifier")
            ?? Self.string(object, "matchIdentifier")
            ?? Self.string(object, "accessoryIdentifier")
            ?? name
        let parts = Self.parts(object)
        return ExternalBatteryDevice(
            // Every piece of one accessory shares an identifier, so the part goes
            // into the id — otherwise ForEach collapses the earbuds into one row.
            id: parts == 0 ? identifier : "\(identifier)#\(parts)",
            name: name,
            groupName: Self.string(object, "groupName"),
            category: Self.category(object),
            vendor: Self.vendorName(object),
            percent: Self.percent(object),
            isCharging: Self.bool(object, "charging"),
            isConnected: Self.bool(object, "connected"),
            isInternal: Self.bool(object, "internal"),
            isLowBattery: Self.bool(object, "lowBattery"),
            isApproximate: Self.bool(object, "approximatesPercentCharge"),
            parts: parts,
            transport: Self.transport(object),
            raw: raw.mapValues { String(describing: $0) }
        )
    }

    /// `parts` is a `BCBatteryDevicePart` bitmask — Left 1, Right 2, Case 4 — not
    /// an array of sub-objects. Each piece of a pair arrives as its own device with
    /// its own `percentCharge` and one bit set here.
    private static func parts(_ object: NSObject) -> Int {
        (object.value(forKeyIfPresent: "parts") as? NSNumber)?.intValue ?? 0
    }

    private static func category(_ object: NSObject) -> ExternalBatteryDevice.Category {
        guard let raw = (object.value(forKeyIfPresent: "accessoryCategory") as? NSNumber)?.intValue else {
            return .unknown
        }
        return ExternalBatteryDevice.Category(rawValue: raw) ?? .unknown
    }

    /// `BCBatteryDeviceVendor`: 0 unknown, 1 Apple, 2 Beats.
    private static func vendorName(_ object: NSObject) -> String? {
        if let text = string(object, "vendor") { return text }
        guard let raw = (object.value(forKeyIfPresent: "vendor") as? NSNumber)?.intValue else { return nil }
        switch raw {
        case 1: return "Apple"
        case 2: return "Beats"
        default: return nil
        }
    }

    private static func transport(_ object: NSObject) -> ExternalBatteryDevice.Transport? {
        guard let raw = (object.value(forKeyIfPresent: "transportType") as? NSNumber)?.intValue else { return nil }
        return ExternalBatteryDevice.Transport(rawValue: raw)
    }

    /// `percentCharge` is an `NSInteger` 0…100. An earlier version treated a value
    /// at or below 1 as a fraction and multiplied by 100, which turned a genuine
    /// 1 % into 100 %.
    private static func percent(_ object: NSObject) -> Int? {
        for key in ["percentCharge", "percent", "batteryLevel"] {
            guard let number = object.value(forKeyIfPresent: key) as? NSNumber else { continue }
            let value = number.intValue
            guard (0...100).contains(value) else { continue }
            return value
        }
        return nil
    }

    private static func string(_ object: NSObject, _ key: String) -> String? {
        object.value(forKeyIfPresent: key) as? String
    }

    private static func bool(_ object: NSObject, _ key: String) -> Bool {
        (object.value(forKeyIfPresent: key) as? NSNumber)?.boolValue ?? false
    }

    /// Every declared property whose type KVC can safely box. Struct-typed
    /// properties are skipped: `value(forKey:)` would raise, and an Objective-C
    /// exception is not catchable from Swift.
    static func readableProperties(of object: NSObject) -> [String: Any] {
        var result: [String: Any] = [:]
        var cls: AnyClass? = type(of: object)
        while let current = cls, current != NSObject.self {
            var count: UInt32 = 0
            if let list = class_copyPropertyList(current, &count) {
                for index in 0..<Int(count) {
                    let property = list[index]
                    let name = String(cString: property_getName(property))
                    guard let encoded = property_getAttributes(property) else { continue }
                    let attributes = String(cString: encoded)
                    guard Self.isBoxable(attributes), let value = object.value(forKeyIfPresent: name) else { continue }
                    result[name] = value
                }
                free(list)
            }
            cls = class_getSuperclass(current)
        }
        return result
    }

    /// Property attribute strings start with `T` followed by the type encoding.
    /// Objects, numbers and booleans box fine; structs, unions and blocks do not.
    private static func isBoxable(_ attributes: String) -> Bool {
        guard let encoding = attributes.dropFirst().first else { return false }
        return "@cCiIsSlLqQfdB".contains(encoding)
    }
}

/// Stands in for `BCBatteryDeviceObserving`. Only the selector matters at runtime,
/// so the protocol itself does not need to be declared.
nonisolated private final class DeviceObserver: NSObject {
    @objc func connectedDevicesDidChange(_ devices: Any?) {}
}

nonisolated private extension NSObject {
    /// `value(forKey:)` raises for an unknown key, and Swift cannot catch that, so
    /// nothing is read without checking for an accessor first.
    ///
    /// The check has to mirror KVC's own search order. Most of `BCBatteryDevice`'s
    /// flags are declared `getter=isCharging`, `getter=isInternal` and so on, so a
    /// bare `responds(to: "charging")` is false even though `value(forKey:)` would
    /// have found it. That is why charging, connected, internal and lowBattery all
    /// silently read as false, and why they were missing from the raw dump.
    func value(forKeyIfPresent key: String) -> Any? {
        let capitalised = key.prefix(1).uppercased() + key.dropFirst()
        let accessors = ["get\(capitalised)", key, "is\(capitalised)", "_\(key)"]
        guard accessors.contains(where: { responds(to: NSSelectorFromString($0)) }) else { return nil }
        return value(forKey: key)
    }
}
