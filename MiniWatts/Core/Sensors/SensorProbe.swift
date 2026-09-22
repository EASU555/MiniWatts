import Foundation

/// Keeps the one permitted HID client and the blocking IOKit calls off the UI
/// actor. The actor serializes reads, rescans, and the debug inventory so a
/// charger transition cannot mutate the service list during a read.
actor SensorProbe {
    /// IOKit returns property-list dictionaries. They are owned by this sample,
    /// never mutated after creation, and only read on the main actor after the
    /// actor hand-off. `Any` prevents the compiler from proving that boundary.
    nonisolated struct Sample: @unchecked Sendable {
        let registry: [String: Any]
        let sources: [[String: Any]]
        let adapterDetails: [String: Any]?
        let chargeStatus: [String: Any]?
        let sensors: [HIDSensors.Reading]
        let ioKitAvailable: Bool
        let hidServiceCount: Int?
        let cpuUsagePercent: Double?
        let elapsedMilliseconds: Double
    }

    private var battery: IOKitBattery?
    private var hid: HIDSensors?
    private var cpuLoad = SystemCPULoadReader()
    private var initialized = false

    private func prepareIfNeeded() {
        guard !initialized else { return }
        initialized = true
        battery = IOKitBattery()
        hid = HIDSensors()
    }

    func read(rescanAfterward: Bool) -> Sample {
        let started = Date.now
        prepareIfNeeded()
        let registry = battery?.readRegistryProperties() ?? [:]
        let sources = battery?.readPowerSources() ?? []
        let adapterDetails = battery?.readAdapterDetails()
        let chargeStatus = battery?.readChargeStatus()
        let readings = hid?.read() ?? []
        let cpuUsagePercent = cpuLoad.read()
        if rescanAfterward { hid?.rescan() }
        return Sample(registry: registry,
                      sources: sources,
                      adapterDetails: adapterDetails,
                      chargeStatus: chargeStatus,
                      sensors: readings,
                      ioKitAvailable: battery != nil,
                      hidServiceCount: hid?.serviceCount,
                      cpuUsagePercent: cpuUsagePercent,
                      elapsedMilliseconds: Date.now.timeIntervalSince(started) * 1000)
    }

    func rescan() {
        prepareIfNeeded()
        hid?.rescan()
    }

    func inventory() -> [HIDSensors.ServiceInfo] {
        prepareIfNeeded()
        return hid?.fullInventory() ?? []
    }
}
