import Foundation
import Observation
import UIKit

/// One point in the rolling live chart.
nonisolated struct LiveSample: Identifiable, Hashable {
    let date: Date
    let inputWatts: Double?
    let batteryWatts: Double?
    let hottestTemperature: Double?
    var id: Date { date }
}

/// Drives every probe on a one-second tick and merges the results into one
/// observable object the whole UI reads from.
@Observable
final class PowerMonitor {
    // MARK: Published state

    private(set) var snapshot = PowerSnapshot()
    private(set) var live: [LiveSample] = []
    private(set) var devices: [ExternalBatteryDevice] = []
    private(set) var sessions: [ChargeSession] = []
    private(set) var currentSession: ChargeSession?
    private(set) var sessionTotals = EnergyTotals()
    /// Watts estimated from how fast the percentage moves. The only way to see
    /// discharge power: no discharge-current sensor is exposed to a sandboxed app.
    private(set) var rateEstimateWatts: Double?
    private(set) var diagnostics: [String] = []
    private(set) var batteryLevelSource = "unavailable"
    private(set) var batteryLevelSampledAt: Date?
    private(set) var batteryLevelChangedAt: Date?
    private(set) var batteryLevelCandidates = "—"
    /// Every power source powerd reports, not just the internal battery.
    ///
    /// BatteryCenter is built on this same list — it has a `_BCPowerSourceController`
    /// and registers for power-source change notifications — so if accessories are
    /// reachable at all from a sandboxed app, they show up here.
    private(set) var powerSources: [[String: Any]] = []
    /// False until the session file has been read. Nothing is written before then:
    /// the load is asynchronous now, and a save that landed first would overwrite
    /// the whole history with an empty array.
    private(set) var isLoaded = false

    /// Whether to hold the screen awake while the phone is plugged in.
    ///
    /// The screen locking is what used to end a charge session two minutes in — the
    /// tick stops with the app, and a full charge could never be recorded. Applied
    /// by `RootView`, which is where UIKit belongs; `Core` stays UI-free.
    var keepScreenAwakeWhileCharging: Bool {
        didSet { UserDefaults.standard.set(keepScreenAwakeWhileCharging, forKey: Self.keepAwakeKey) }
    }

    /// Manually controls the persistent Live Activity. It stays up across charger
    /// changes until the user turns it off; ActivityKit owns the surface while the
    /// sensor tick remains the single source of truth for its content.
    var liveActivityEnabled: Bool {
        didSet {
            UserDefaults.standard.set(liveActivityEnabled, forKey: Self.liveActivityEnabledKey)
            if liveActivityEnabled {
                liveActivityController.restart(snapshot: snapshot,
                                               leadingItem: liveActivityLeadingItem,
                                               selectedMetric: liveActivityMetric)
            } else {
                liveActivityController.endIfNeeded()
            }
        }
    }

    var liveActivityLeadingItem: LiveActivityLeadingItem {
        didSet {
            UserDefaults.standard.set(liveActivityLeadingItem.rawValue,
                                      forKey: Self.liveActivityLeadingItemKey)
            liveActivityController.reconcile(snapshot: snapshot,
                                             leadingItem: liveActivityLeadingItem,
                                             selectedMetric: liveActivityMetric,
                                             enabled: liveActivityEnabled,
                                             forceUpdate: true)
        }
    }

    var liveActivityMetric: LiveActivityMetric {
        didSet {
            UserDefaults.standard.set(liveActivityMetric.rawValue, forKey: Self.liveActivityMetricKey)
            liveActivityController.reconcile(snapshot: snapshot,
                                             leadingItem: liveActivityLeadingItem,
                                             selectedMetric: liveActivityMetric,
                                             enabled: liveActivityEnabled,
                                             forceUpdate: true)
        }
    }

    var liveActivitiesAvailable: Bool {
        ChargingLiveActivityController.areActivitiesEnabled
    }

    /// Explicit recovery path for an ActivityKit presentation that disappeared
    /// while its retained Activity object still claims to be active.
    func restartLiveActivity() {
        guard liveActivityEnabled else {
            liveActivityEnabled = true
            return
        }
        liveActivityController.restart(snapshot: snapshot,
                                       leadingItem: liveActivityLeadingItem,
                                       selectedMetric: liveActivityMetric)
    }

    func recoverLiveActivityAfterEnteringForeground() {
        guard liveActivityEnabled else { return }
        liveActivityController.recoverAfterEnteringForeground(
            snapshot: snapshot,
            leadingItem: liveActivityLeadingItem,
            selectedMetric: liveActivityMetric
        )
    }

    let thermal = ThermalMonitor()

    /// Direct fan-out from the sensor tick. Unlike a SwiftUI `onChange`, this
    /// continues while Picture in Picture keeps the process running off screen.
    @ObservationIgnored var onTick: ((PowerSnapshot) -> Void)?

    /// Usable pack energy, used to turn %/h into watts. Read from IOKit where the
    /// sandbox allows it, otherwise from the value the user sets in Settings.
    var batteryWattHours: Double {
        get {
            if let capacity = snapshot.designCapacity, capacity > 0 {
                return Double(capacity) * Self.nominalCellVoltage / 1000
            }
            return configuredBatteryWattHours
        }
    }

    var configuredBatteryWattHours: Double {
        didSet { UserDefaults.standard.set(configuredBatteryWattHours, forKey: Self.wattHoursKey) }
    }

    var sensorsAvailable: Bool { sensors != nil && !(sensors?.isEmpty ?? true) }
    var deviceModelIdentifier: String { Self.machineIdentifier }

    // MARK: Private

    private static let nominalCellVoltage = 3.87
    private static let wattHoursKey = "batteryWattHours"
    private static let keepAwakeKey = "keepScreenAwakeWhileCharging"
    // A new key deliberately does not inherit the old "automatic while charging"
    // preference. Build 12 changes this to an explicit persistent user action.
    private static let liveActivityEnabledKey = "liveActivityManualEnabled"
    private static let liveActivityLeadingItemKey = "liveActivityLeadingItem"
    private static let liveActivityMetricKey = "liveActivityMetric"
    private static let liveWindow = 180
    private static let maximumContinuousSampleInterval: TimeInterval = 10
    private static let rateEstimateMaximumAge: TimeInterval = 30 * 60

    private let battery = IOKitBattery()
    private let systemBatteryLevel = SystemBatteryLevelReader()
    private let sensors = HIDSensors()
    private let batteryCenter = BatteryCenterBridge()
    private let energy = EnergyAccumulator()
    private let store = SessionStore()
    private let liveActivityController = ChargingLiveActivityController()

    private var task: Task<Void, Never>?
    private var lastRefreshStartedAt = Date.distantPast
    private var tick = 0
    private var lastSampleWrite: Date = .distantPast
    private var lastPersist: Date = .distantPast
    private var lastExternalConnected: Bool?
    /// The last moment the phone was actually observed plugged in. A session is
    /// closed at this point rather than at `.now`, so a charge that ended while the
    /// app was suspended is not recorded as having run until the app came back.
    private var lastConnectedObservation: Date?
    /// Set by `deleteAllSessions`. The load is asynchronous, so a delete that lands
    /// while it is still in flight would otherwise have the file's contents merged
    /// back in on top of it a moment later.
    private var discardedStoredSessions = false
    private var percentLog: [(date: Date, percent: Int)] = []
    private var lastChargingFlag: Bool?
    private var lastThermalObservation: (date: Date, wasThrottling: Bool)?
    private var diagnosticEvents: [String] = []

    init() {
        let defaults = UserDefaults.standard
        let stored = defaults.double(forKey: Self.wattHoursKey)
        configuredBatteryWattHours = stored > 0 ? stored : 15.0
        // Defaults to on: recording a whole charge is the point of the History tab,
        // and it cannot happen if the screen locks after thirty seconds.
        keepScreenAwakeWhileCharging = defaults.object(forKey: Self.keepAwakeKey) as? Bool ?? true
        liveActivityEnabled = defaults.object(forKey: Self.liveActivityEnabledKey) as? Bool ?? false
        liveActivityLeadingItem = defaults.string(forKey: Self.liveActivityLeadingItemKey)
            .flatMap(LiveActivityLeadingItem.init(rawValue:)) ?? .statusIcon
        liveActivityMetric = defaults.string(forKey: Self.liveActivityMetricKey)
            .flatMap(LiveActivityMetric.init(rawValue:)) ?? .chargingPower
        systemBatteryLevel.onSystemChange = { [weak self] in
            self?.refreshIfDue(minimumInterval: 0)
        }
        collectDiagnostics()
        appendDiagnosticEvent("monitor initialized")
        Task { await loadStoredSessions() }
    }

    /// Reads the session file off the main thread and merges it in.
    private func loadStoredSessions() async {
        let stored = await store.loaded()
        guard !discardedStoredSessions else {
            isLoaded = true
            return
        }
        let restored = stored.map { session in
            // A session left open by a crash or a force quit is closed at its
            // last recorded point rather than being resumed.
            guard session.end == nil else { return session }
            var closed = session
            closed.end = session.start.addingTimeInterval(session.samples.last?.offset ?? 0)
            return closed
        }
        .filter(Self.isWorthKeeping)
        // A charge may have started and finished while the file was being read, so
        // merge rather than assign, keeping whatever this run has already recorded.
        let known = Set(sessions.map(\.id))
        sessions = (sessions + restored.filter { !known.contains($0.id) })
            .sorted { $0.start > $1.start }
        isLoaded = true
    }

    // MARK: Lifecycle

    func start() {
        systemBatteryLevel.prepareForForeground()
        guard task == nil else { return }
        appendDiagnosticEvent("sampling started")
        refresh()
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }

    /// Stops the tick but leaves any open session open.
    ///
    /// This is what ordinary backgrounding does now; an active floating PiP keeps the
    /// tick running. Backgrounding used to close the session, which made
    /// the History tab close to useless: `scenePhase` leaves `.active` for a pulled-down
    /// Control Center, an incoming call, the app switcher and the screen locking, so an
    /// overnight charge was recorded as a scatter of two-minute fragments instead of one
    /// session. The integrator already discards gaps longer than ten seconds, so a
    /// resumed session reports honest totals and `integratedSeconds` records how much of
    /// the wall clock was actually watched.
    func pause() {
        task?.cancel()
        task = nil
        appendDiagnosticEvent("sampling paused")
        persist()
    }

    /// A hidden video-call PiP can keep a compositor callback alive more reliably
    /// than a sleeping task in the background. Coalesce both drivers here so they
    /// never perform the relatively expensive IOKit/HID read twice in one second.
    func refreshIfDue(minimumInterval: TimeInterval = 0.8) {
        guard Date.now.timeIntervalSince(lastRefreshStartedAt) >= minimumInterval else { return }
        refresh()
    }

    // MARK: Refresh

    func refresh() {
        lastRefreshStartedAt = .now
        tick += 1
        thermal.update()

        let registry = battery?.readRegistryProperties() ?? [:]
        let sources = battery?.readPowerSources() ?? []
        #if DEBUG
        // Only the Raw data screen reads this, and that screen is Debug-only, so a
        // Release build was republishing the whole array once a second for nobody.
        powerSources = sources
        #endif
        let internalBattery = sources.first { ($0["Type"] as? String) == "InternalBattery" } ?? sources.first
        let levelReading = systemBatteryLevel.read(powerSource: internalBattery)
        updateBatteryLevelDiagnostics(levelReading)

        let current = PowerSnapshot(date: .now,
                                    systemBatteryPercent: levelReading?.percent,
                                    registry: registry,
                                    powerSource: internalBattery,
                                    adapterDetails: battery?.readAdapterDetails(),
                                    sensors: sensors?.read() ?? [],
                                    chargeStatus: battery?.readChargeStatus())
        snapshot = current

        // Charger-side sensors only exist while something is plugged in, so the
        // service list is re-enumerated on every plug event and occasionally after.
        if lastExternalConnected != current.externalConnected || tick % 15 == 0 {
            sensors?.rescan()
        }
        if tick % 5 == 1 {
            devices = batteryCenter.read()
        }

        appendLive(current)
        updateRateEstimate(current)
        updateSession(current)
        liveActivityController.reconcile(snapshot: current,
                                         leadingItem: liveActivityLeadingItem,
                                         selectedMetric: liveActivityMetric,
                                         enabled: liveActivityEnabled)
        lastExternalConnected = current.externalConnected
        onTick?(current)
    }

    private func appendLive(_ snapshot: PowerSnapshot) {
        let sample = LiveSample(date: snapshot.date,
                                inputWatts: snapshot.inputWatts,
                                batteryWatts: snapshot.batteryWatts,
                                hottestTemperature: snapshot.hottestSensor?.value)
        live.append(sample)
        if live.count > Self.liveWindow {
            live.removeFirst(live.count - Self.liveWindow)
        }
    }

    // MARK: Sessions

    private func updateSession(_ snapshot: PowerSnapshot) {
        if snapshot.externalConnected {
            lastConnectedObservation = snapshot.date
            if currentSession == nil {
                openSession(snapshot)
            }
            energy.add(snapshot)
            sessionTotals = energy.totals
            recordSample(snapshot)
        } else {
            closeSessionIfNeeded()
        }

        if currentSession != nil, snapshot.date.timeIntervalSince(lastPersist) >= 30 {
            persist()
        }
    }

    private func openSession(_ snapshot: PowerSnapshot) {
        energy.reset()
        sessionTotals = energy.totals
        currentSession = ChargeSession(start: snapshot.date,
                                       startPercent: snapshot.percent ?? 0,
                                       adapterName: snapshot.adapterName,
                                       adapterRatedWatts: snapshot.adapterRatedWatts,
                                       isWireless: snapshot.isWirelessInput)
        lastSampleWrite = .distantPast
        lastThermalObservation = nil
    }

    private func recordSample(_ snapshot: PowerSnapshot) {
        guard var session = currentSession else { return }

        session.endPercent = snapshot.percent ?? session.endPercent
        session.totals = energy.totals
        if let inputWatts = snapshot.inputWatts {
            session.peakInputWatts = max(session.peakInputWatts, inputWatts)
        }
        if let batteryWatts = snapshot.batteryWatts {
            session.peakBatteryWatts = max(session.peakBatteryWatts, batteryWatts)
        }
        if let temperature = snapshot.batteryTemperature {
            session.peakBatteryTemperature = max(session.peakBatteryTemperature ?? temperature, temperature)
        }
        // The adapter identifies itself a beat after the plug event, so the name
        // is filled in whenever it first becomes available.
        if session.adapterName == nil { session.adapterName = snapshot.adapterName }
        if session.adapterRatedWatts == nil { session.adapterRatedWatts = snapshot.adapterRatedWatts }
        if let previous = lastThermalObservation {
            let interval = snapshot.date.timeIntervalSince(previous.date)
            if interval > 0,
               interval <= Self.maximumContinuousSampleInterval,
               previous.wasThrottling {
                session.throttledSeconds += interval
            }
        }
        lastThermalObservation = (snapshot.date, thermal.state.isThrottling)

        if snapshot.date.timeIntervalSince(lastSampleWrite) >= SessionStore.sampleInterval {
            lastSampleWrite = snapshot.date
            session.samples.append(ChargeSample(offset: snapshot.date.timeIntervalSince(session.start),
                                                inputWatts: snapshot.inputWatts,
                                                batteryWatts: snapshot.batteryWatts,
                                                percent: snapshot.percent ?? session.endPercent,
                                                batteryTemperature: snapshot.batteryTemperature,
                                                hottestTemperature: snapshot.hottestSensor?.value,
                                                throttled: thermal.state.isThrottling))
            // A very long charge is thinned in place: every other point goes, which
            // halves the resolution without losing the shape of the curve.
            if session.samples.count > SessionStore.sampleLimit {
                session.samples = session.samples.enumerated().compactMap { $0.offset.isMultiple(of: 2) ? $0.element : nil }
            }
        }
        currentSession = session
    }

    private func closeSessionIfNeeded() {
        guard var session = currentSession else { return }
        // The end is the last moment the charger was actually seen, not now. Unplug
        // the phone while the app is suspended and the next tick after it wakes is
        // the first that knows — dating the end from that tick would stretch every
        // such session across however long the app was away.
        session.end = max(lastConnectedObservation ?? snapshot.date, session.start)
        lastConnectedObservation = nil
        session.totals = energy.totals
        currentSession = nil
        lastThermalObservation = nil
        energy.reset()
        sessionTotals = EnergyTotals()
        if Self.isWorthKeeping(session) {
            sessions.insert(session, at: 0)
        }
        // Persist either way: the periodic save wrote this session while it was
        // open, so the file has to be rewritten even when it is being discarded.
        persist()
    }

    /// A stretch of being plugged in that moved no energy is a cable reseat, or a
    /// phone sitting at 100 %, not a charge worth keeping.
    private static func isWorthKeeping(_ session: ChargeSession) -> Bool {
        session.totals.inputWattHours > 0.001
            || session.totals.batteryWattHours > 0.001
            || session.gainedPercent > 0
    }

    private func persist() {
        guard isLoaded else { return }
        lastPersist = .now
        store.save(sessions + (currentSession.map { [$0] } ?? []))
    }

    func deleteSession(_ session: ChargeSession) {
        sessions.removeAll { $0.id == session.id }
        persist()
    }

    func deleteAllSessions() {
        discardedStoredSessions = true
        sessions.removeAll()
        currentSession = nil
        lastThermalObservation = nil
        energy.reset()
        sessionTotals = EnergyTotals()
        store.deleteAll()
    }

    // MARK: Rate estimate

    /// Tracks 1 % transitions and converts the slope into watts. Two transitions
    /// are needed because the first sample lands mid-percent.
    private func updateRateEstimate(_ snapshot: PowerSnapshot) {
        guard let percent = snapshot.percent else {
            rateEstimateWatts = nil
            return
        }
        if lastChargingFlag != snapshot.isCharging {
            lastChargingFlag = snapshot.isCharging
            percentLog.removeAll()
            rateEstimateWatts = nil
        }
        if let last = percentLog.last,
           snapshot.date.timeIntervalSince(last.date) > Self.rateEstimateMaximumAge {
            percentLog = [(snapshot.date, percent)]
            rateEstimateWatts = nil
            return
        }
        if percentLog.last?.percent != percent {
            percentLog.append((snapshot.date, percent))
            if percentLog.count > 7 { percentLog.removeFirst(percentLog.count - 7) }
        }
        guard percentLog.count >= 3,
              let first = percentLog.first,
              let last = percentLog.last,
              abs(last.percent - first.percent) >= 2 else {
            rateEstimateWatts = nil
            return
        }
        let hours = last.date.timeIntervalSince(first.date) / 3600
        guard hours > 0 else { return }
        rateEstimateWatts = Double(last.percent - first.percent) / 100 * batteryWattHours / hours
    }

    // MARK: Headline

    /// The number on the dial and the caption under it.
    ///
    /// This lives here rather than in `PowerSnapshot` because the last fallback —
    /// the %-rate estimate — is the monitor's, not the snapshot's: it is derived
    /// from how the percentage moved across several snapshots. `PowerSnapshot` used
    /// to carry a `primaryWatts` that answered a simpler version of the same
    /// question, which nothing called, while `DashboardView` open-coded this. One
    /// answer, in the layer that can actually give it.
    var headline: (watts: Double, caption: LocalizedStringResource)? {
        if snapshot.externalConnected {
            let power = snapshot.chargingPower
            if let watts = power.watts, !power.isBatterySide {
                // Written out rather than as a ternary in the tuple. The string
                // extractor took only the first branch there — "from charger" never
                // reached the catalog and the dial's caption fell back to English on
                // every wired charge. `Text` and `LocalizedStringResource` literals
                // want to be at their own return site.
                if snapshot.isWirelessInput { return (watts, "from MagSafe") }
                return (watts, "from charger")
            }
            // Wireless charging has no input-current sensor — the PMU exposes the
            // coil voltage and nothing to multiply it by — so rather than reading
            // "no reading" while the phone is visibly charging, the dial drops to
            // the battery side and says so. A measured zero is still a reading: a
            // phone sitting at 100 % on a charger is genuinely taking nothing.
            if let watts = power.watts { return (watts, "into battery") }
            return nil
        }
        if let watts = snapshot.batteryWatts, watts != 0 { return (abs(watts), "drawn from battery") }
        if let watts = rateEstimateWatts { return (abs(watts), "from battery (%-rate estimate)") }
        return nil
    }

    // MARK: Diagnostics

    private func collectDiagnostics() {
        var lines: [String] = []
        lines.append("IOKit: \(battery == nil ? "unavailable" : "loaded")")
        lines.append("HID sensors: \(sensors == nil ? "unavailable" : "\(sensors?.serviceCount ?? 0) services")")
        lines.append("BatteryCenter: \(batteryCenter.status) via \(batteryCenter.controllerOrigin)")
        lines.append("Device: \(Self.machineIdentifier)")
        #if targetEnvironment(simulator)
        lines.append("Simulator: IOKit reads the Mac's battery, HID sensors are absent.")
        #endif
        diagnostics = lines
    }

    private func updateBatteryLevelDiagnostics(_ reading: SystemBatteryLevelReader.Reading?) {
        let oldPercent = snapshot.percent
        let oldSource = batteryLevelSource
        guard let reading else {
            batteryLevelSource = "unavailable"
            batteryLevelSampledAt = .now
            batteryLevelCandidates = "MobileGestalt — · powerd — · UIDevice —"
            if oldSource != batteryLevelSource {
                appendDiagnosticEvent("battery level unavailable")
            }
            return
        }

        batteryLevelSource = reading.source.rawValue
        batteryLevelSampledAt = reading.sampledAt
        batteryLevelCandidates = [
            "MobileGestalt \(reading.mobileGestaltPercent.map(String.init) ?? "—")",
            "powerd \(reading.powerSourcePercent.map(String.init) ?? "—")",
            "UIDevice \(reading.uiDevicePercent.map(String.init) ?? "—")"
        ].joined(separator: " · ")

        if oldPercent != reading.percent || oldSource != batteryLevelSource {
            batteryLevelChangedAt = reading.sampledAt
            appendDiagnosticEvent(
                "battery \(oldPercent.map(String.init) ?? "—")% -> \(reading.percent)% "
                    + "via \(batteryLevelSource) [\(batteryLevelCandidates)]"
            )
        }
    }

    private func appendDiagnosticEvent(_ message: String) {
        diagnosticEvents.append("\(Formatting.timestamp(.now))  \(message)")
        if diagnosticEvents.count > 120 {
            diagnosticEvents.removeFirst(diagnosticEvents.count - 120)
        }
    }

    /// A local-only report the user can explicitly export from Settings. It avoids
    /// serial numbers and identifiers while retaining enough source detail to tell
    /// a frozen UIKit level from a stopped sampling loop.
    var diagnosticReport: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        var lines = [
            "MiniWatts diagnostics",
            "Generated: \(Formatting.timestamp(.now))",
            "Version: \(version) (\(build))",
            "Device: \(Self.machineIdentifier)",
            "System: iOS \(UIDevice.current.systemVersion)",
            "Battery: \(snapshot.percent.map(String.init) ?? "—")% via \(batteryLevelSource)",
            "Battery candidates: \(batteryLevelCandidates)",
            "Battery sampled: \(batteryLevelSampledAt.map(Formatting.timestamp) ?? "—")",
            "Battery last changed: \(batteryLevelChangedAt.map(Formatting.timestamp) ?? "—")",
            "Snapshot: \(Formatting.timestamp(snapshot.date))",
            "External power: \(snapshot.externalConnected)",
            "Charging: \(snapshot.isCharging)",
            "Input watts: \(snapshot.inputWatts.map { String(format: "%.3f", $0) } ?? "—")",
            "Battery watts: \(snapshot.batteryWatts.map { String(format: "%.3f", $0) } ?? "—")",
            "Thermal state: \(thermal.state.rawValue)",
            "PiP background tick: \(task == nil ? "stopped" : "running")",
            "",
            "# Probe availability"
        ]
        lines.append(contentsOf: diagnostics)
        lines.append("")
        lines.append("# Recent events")
        lines.append(contentsOf: diagnosticEvents)
        lines.append("")
        lines.append("# Live sensors")
        lines.append(contentsOf: snapshot.sensors.sorted { $0.name < $1.name }
            .map { "\($0.name) = \($0.formatted)" })
        if let powerSource = snapshot.powerSource, !powerSource.isEmpty {
            lines.append("")
            lines.append("# powerd power source")
            lines.append(contentsOf: powerSource.keys.sorted().map {
                "\($0) = \(String(describing: powerSource[$0]!))"
            })
        }
        return lines.joined(separator: "\n")
    }

    /// Why the accessory list is empty, in the app's voice, for the Devices screen.
    var batteryCenterStatus: LocalizedStringResource? { batteryCenter.status.userMessage }

    /// The same thing with the failing step named, for Raw data.
    var batteryCenterDiagnostic: LocalizedStringResource? { batteryCenter.status.diagnostic }

    /// Every HID service in the system, for the debug view.
    func hidInventory() -> [HIDSensors.ServiceInfo] {
        sensors?.fullInventory() ?? []
    }

    private static let machineIdentifier: String = {
        // Inside a simulator `uname` reports the Mac's architecture, so the
        // simulated model identifier is taken from the environment instead.
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return "\(simulated) (simulator)"
        }
        var info = utsname()
        guard uname(&info) == 0 else { return "unknown" }
        // `info.machine` is a fixed-size C array; mirroring it avoids taking an
        // overlapping pointer to the struct that is still being written.
        return Mirror(reflecting: info.machine).children.reduce(into: "") { result, element in
            guard let byte = element.value as? Int8, byte != 0 else { return }
            result.append(Character(UnicodeScalar(UInt8(byte))))
        }
    }()
}
