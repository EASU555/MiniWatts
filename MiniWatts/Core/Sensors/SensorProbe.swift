import Foundation

/// Reports the currently executing blocking stage without waiting for the probe
/// actor itself. This lets a timeout report where a private call got stuck.
nonisolated final class SensorProbeProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var stage = "idle"
    private var changedAt = Date.now

    func mark(_ stage: String) {
        lock.lock()
        self.stage = stage
        changedAt = .now
        lock.unlock()
    }

    var diagnostic: String {
        lock.lock()
        defer { lock.unlock() }
        return "stage=\(stage) stageAge=\(String(format: "%.1f", max(0, Date.now.timeIntervalSince(changedAt))))s"
    }
}

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
        let cpuSampledAt: Date
        let cpuIntervalSeconds: TimeInterval?
        let network: NetworkTrafficReader.Sample
        let startedAt: Date
        let finishedAt: Date
        let elapsedMilliseconds: Double
    }

    private var battery: IOKitBattery?
    private var hid: HIDSensors?
    private var cpuLoad = SystemCPULoadReader()
    private var networkTraffic = NetworkTrafficReader()
    private var initialized = false
    private let readsHID: Bool
    nonisolated let progress = SensorProbeProgress()

    init(readsHID: Bool = true) {
        self.readsHID = readsHID
    }

    private func prepareIfNeeded() {
        guard !initialized else { return }
        initialized = true
        battery = IOKitBattery()
        if readsHID { hid = HIDSensors() }
    }

    func read(rescanAfterward: Bool) -> Sample {
        let started = Date.now
        progress.mark("initializing")
        prepareIfNeeded()
        // Read the lightweight CPU counters before the HID/powerd sweep. A slow
        // private sensor must not shift the CPU interval within this probe.
        progress.mark("cpu")
        let cpuSample = cpuLoad.read()
        progress.mark("network")
        let networkSample = networkTraffic.read()
        progress.mark("registry")
        let registry = battery?.readRegistryProperties() ?? [:]
        progress.mark("powerSources")
        let sources = battery?.readPowerSources() ?? []
        progress.mark("adapter")
        let adapterDetails = battery?.readAdapterDetails()
        progress.mark("chargeStatus")
        let chargeStatus = battery?.readChargeStatus()
        progress.mark("hidRead")
        let readings = hid?.read() ?? []
        if rescanAfterward {
            progress.mark("hidRescan")
            hid?.rescan()
        }
        let finished = Date.now
        progress.mark("idle")
        return Sample(registry: registry,
                      sources: sources,
                      adapterDetails: adapterDetails,
                      chargeStatus: chargeStatus,
                      sensors: readings,
                      ioKitAvailable: battery != nil,
                      hidServiceCount: hid?.serviceCount,
                      cpuUsagePercent: cpuSample.percent,
                      cpuSampledAt: cpuSample.sampledAt,
                      cpuIntervalSeconds: cpuSample.intervalSeconds,
                      network: networkSample,
                      startedAt: started,
                      finishedAt: finished,
                      elapsedMilliseconds: finished.timeIntervalSince(started) * 1000)
    }

    func rescan() {
        progress.mark("hidRescan")
        prepareIfNeeded()
        hid?.rescan()
        progress.mark("idle")
    }

    func inventory() -> [HIDSensors.ServiceInfo] {
        prepareIfNeeded()
        return hid?.fullInventory() ?? []
    }
}
