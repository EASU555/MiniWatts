import Foundation

/// Enumerates every Apple vendor power sensor so the device, rather than a
/// hard-coded model table, tells the experiment which rails are available.
nonisolated final class HIDSensors {
    enum Kind: Int, Codable, Sendable {
        case current = 2
        case voltage = 3
        case temperature = 5
        case other = 0
    }

    struct Reading: Identifiable, Hashable, Sendable {
        let name: String
        let kind: Kind
        let value: Double
        let index: Int
        var id: String { "\(index)#\(name)" }
    }

    private typealias CreateFn = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
    private typealias SetMatchingFn = @convention(c) (CFTypeRef, CFDictionary?) -> Void
    private typealias CopyServicesFn = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
    private typealias CopyPropertyFn = @convention(c) (CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?
    private typealias CopyEventFn = @convention(c) (CFTypeRef, Int64, Int32, Int64) -> Unmanaged<CFTypeRef>?
    private typealias GetFloatFn = @convention(c) (CFTypeRef, Int32) -> Double

    private static let powerEventType: Int64 = 25
    private static let temperatureEventType: Int64 = 15
    private static let powerUsagePage = 0xff08
    private static let vendorUsagePage = 0xff00

    private struct Service {
        let reference: CFTypeRef
        let name: String
        let usage: Int
        let eventType: Int64
    }

    private let client: CFTypeRef
    private let setMatching: SetMatchingFn
    private let copyServices: CopyServicesFn
    private let copyProperty: CopyPropertyFn
    private let copyEvent: CopyEventFn
    private let getFloat: GetFloatFn
    private var services: [Service] = []

    init?() {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else {
            return nil
        }
        func symbol<T>(_ name: String, _ type: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: type) }
        }
        guard let create = symbol("IOHIDEventSystemClientCreate", CreateFn.self),
              let setMatching = symbol("IOHIDEventSystemClientSetMatching", SetMatchingFn.self),
              let copyServices = symbol("IOHIDEventSystemClientCopyServices", CopyServicesFn.self),
              let copyProperty = symbol("IOHIDServiceClientCopyProperty", CopyPropertyFn.self),
              let copyEvent = symbol("IOHIDServiceClientCopyEvent", CopyEventFn.self),
              let getFloat = symbol("IOHIDEventGetFloatValue", GetFloatFn.self),
              let client = create(kCFAllocatorDefault)?.takeRetainedValue()
        else { return nil }

        self.client = client
        self.setMatching = setMatching
        self.copyServices = copyServices
        self.copyProperty = copyProperty
        self.copyEvent = copyEvent
        self.getFloat = getFloat
        rescan()
    }

    var serviceCount: Int { services.count }

    func rescan() {
        var found = discover(
            matching: ["PrimaryUsagePage": Self.powerUsagePage],
            eventType: Self.powerEventType
        )
        found += discover(
            matching: ["PrimaryUsagePage": Self.vendorUsagePage, "PrimaryUsage": 5],
            eventType: Self.temperatureEventType
        )
        services = found
    }

    func read() -> [Reading] {
        services.enumerated().compactMap { index, service in
            guard let event = copyEvent(service.reference, service.eventType, 0, 0)?.takeRetainedValue()
            else { return nil }
            let value = getFloat(event, Int32(service.eventType << 16))
            guard value.isFinite else { return nil }
            return Reading(
                name: service.name,
                kind: Kind(rawValue: service.usage) ?? .other,
                value: value,
                index: index
            )
        }
    }

    private func discover(matching: [String: Any]?, eventType: Int64) -> [Service] {
        setMatching(client, matching as CFDictionary?)
        let references = copyServices(client)?.takeRetainedValue() as? [CFTypeRef] ?? []
        return references.map { reference in
            func number(_ key: String) -> Int {
                (copyProperty(reference, key as CFString)?.takeRetainedValue() as? NSNumber)?.intValue ?? 0
            }
            let name = copyProperty(reference, "Product" as CFString)?.takeRetainedValue() as? String ?? "?"
            return Service(reference: reference, name: name, usage: number("PrimaryUsage"), eventType: eventType)
        }
    }
}
