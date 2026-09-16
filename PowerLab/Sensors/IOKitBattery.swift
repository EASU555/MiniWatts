import Foundation

/// Minimal, read-only bridge to the same IOKit power-source functions used by
/// MiniWatts. Every symbol is resolved dynamically because IOKit is private on
/// iOS. PowerLab is a sideload-only diagnostic app.
nonisolated final class IOKitBattery {
    private typealias ServiceMatchingFn =
        @convention(c) (UnsafePointer<CChar>) -> Unmanaged<CFDictionary>?
    private typealias GetMatchingServiceFn =
        @convention(c) (mach_port_t, CFDictionary?) -> UInt32
    private typealias CreatePropertiesFn =
        @convention(c) (UInt32, UnsafeMutablePointer<Unmanaged<CFDictionary>?>?, CFAllocator?, UInt32) -> kern_return_t
    private typealias ObjectReleaseFn = @convention(c) (UInt32) -> kern_return_t
    private typealias CopyPowerSourcesInfoFn = @convention(c) () -> Unmanaged<CFTypeRef>?
    private typealias CopyPowerSourcesListFn = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
    private typealias GetPowerSourceDescriptionFn =
        @convention(c) (CFTypeRef, CFTypeRef) -> Unmanaged<CFDictionary>?

    private let serviceMatching: ServiceMatchingFn
    private let getMatchingService: GetMatchingServiceFn
    private let createProperties: CreatePropertiesFn
    private let objectRelease: ObjectReleaseFn
    private let copyPowerSourcesInfo: CopyPowerSourcesInfoFn?
    private let copyPowerSourcesList: CopyPowerSourcesListFn?
    private let powerSourceDescription: GetPowerSourceDescriptionFn?

    init?() {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else {
            return nil
        }
        func symbol<T>(_ name: String, _ type: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: type) }
        }
        guard let matching = symbol("IOServiceMatching", ServiceMatchingFn.self),
              let getService = symbol("IOServiceGetMatchingService", GetMatchingServiceFn.self),
              let properties = symbol("IORegistryEntryCreateCFProperties", CreatePropertiesFn.self),
              let release = symbol("IOObjectRelease", ObjectReleaseFn.self)
        else { return nil }

        serviceMatching = matching
        getMatchingService = getService
        createProperties = properties
        objectRelease = release
        copyPowerSourcesInfo = symbol("IOPSCopyPowerSourcesInfo", CopyPowerSourcesInfoFn.self)
        copyPowerSourcesList = symbol("IOPSCopyPowerSourcesList", CopyPowerSourcesListFn.self)
        powerSourceDescription = symbol("IOPSGetPowerSourceDescription", GetPowerSourceDescriptionFn.self)
    }

    func readRegistryProperties(className: String = "IOPMPowerSource") -> [String: Any]? {
        guard let matching = serviceMatching(className) else { return nil }
        let service = getMatchingService(0, matching.takeUnretainedValue())
        guard service != 0 else { return nil }
        defer { _ = objectRelease(service) }

        var properties: Unmanaged<CFDictionary>?
        guard createProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dictionary = properties?.takeRetainedValue()
        else { return nil }
        return dictionary as? [String: Any]
    }

    func readPowerSources() -> [[String: Any]] {
        guard let copyPowerSourcesInfo,
              let copyPowerSourcesList,
              let powerSourceDescription,
              let blob = copyPowerSourcesInfo()?.takeRetainedValue(),
              let list = copyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return [] }

        return list.compactMap {
            powerSourceDescription(blob, $0)?.takeUnretainedValue() as? [String: Any]
        }
    }
}
