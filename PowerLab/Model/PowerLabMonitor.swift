import Foundation
import Observation

nonisolated enum TestMarker: String, CaseIterable, Identifiable, Codable, Sendable {
    case baseline = "待机基线"
    case cpuLoad = "CPU 负载"
    case screen = "高亮屏幕"
    case camera = "相机"
    case game = "游戏"
    case custom = "自定义"

    var id: Self { self }
}

nonisolated struct RecordedPowerSample: Codable, Sendable {
    let marker: TestMarker
    let sample: ProbeSample
    let estimate: PowerEstimate
}

@Observable
@MainActor
final class PowerLabMonitor {
    private(set) var latestSample: ProbeSample?
    private(set) var estimate: PowerEstimate?
    private(set) var history: [PowerHistoryPoint] = []
    private(set) var isRecording = false
    private(set) var recordedSamples: [RecordedPowerSample] = []
    private(set) var exportURL: URL?
    private(set) var loadTestRemaining = 0
    private(set) var lastError: String?

    var marker: TestMarker = .baseline
    var capacityWh: Double {
        didSet { UserDefaults.standard.set(capacityWh, forKey: Self.capacityKey) }
    }

    let sampleInterval: TimeInterval = 1

    private static let capacityKey = "PowerLabBatteryCapacityWh"
    let sensorMode: SensorMode
    private let probe: PowerProbe
    private let estimator = PowerEstimator()
    private var samplingTask: Task<Void, Never>?
    private var loadWorkers: [Task<Void, Never>] = []
    private var loadCountdownTask: Task<Void, Never>?

    init(sensorMode: SensorMode) {
        self.sensorMode = sensorMode
        probe = PowerProbe(mode: sensorMode)
        let stored = UserDefaults.standard.double(forKey: Self.capacityKey)
        capacityWh = stored > 0 ? stored : 19.7
    }

    var probeStatus: String { probe.status }
    var isLoadTestRunning: Bool { loadTestRemaining > 0 }

    func start() {
        guard samplingTask == nil else { return }
        sampleNow()
        samplingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.sampleNow()
            }
        }
    }

    func stop() {
        samplingTask?.cancel()
        samplingTask = nil
        stopLoadTest()
    }

    func sampleNow() {
        let sample = probe.capture()
        let nextEstimate = estimator.ingest(sample, capacityWh: capacityWh)
        latestSample = sample
        estimate = nextEstimate

        if let watts = nextEstimate.watts {
            history.append(PowerHistoryPoint(
                date: sample.date,
                watts: watts,
                measured: nextEstimate.mode == .measured
            ))
            if history.count > 900 { history.removeFirst(history.count - 900) }
        }

        if isRecording {
            recordedSamples.append(RecordedPowerSample(
                marker: marker,
                sample: sample,
                estimate: nextEstimate
            ))
            exportURL = nil
        }

        if ProcessInfo.processInfo.thermalState == .serious
            || ProcessInfo.processInfo.thermalState == .critical {
            stopLoadTest()
        }
    }

    func startRecording() {
        recordedSamples.removeAll(keepingCapacity: true)
        exportURL = nil
        lastError = nil
        isRecording = true
    }

    func stopRecording() {
        isRecording = false
        prepareExport()
    }

    func clearRecording() {
        isRecording = false
        recordedSamples.removeAll()
        exportURL = nil
        lastError = nil
    }

    func prepareExport() {
        guard !recordedSamples.isEmpty else {
            exportURL = nil
            return
        }

        let formatter = ISO8601DateFormatter()
        var rows = [
            "timestamp,marker,percent,external_power,is_charging,mode,source,filtered_watts,raw_watts,voltage,current,confidence,battery_temperature,thermal_state,power_candidates,hid_channels"
        ]
        rows += recordedSamples.map { record in
            let sample = record.sample
            let estimate = record.estimate
            let candidates = sample.candidates.map {
                "\($0.name):\(Self.number($0.voltage))V*\(Self.number($0.current))A=\(Self.number($0.signedWatts))W"
            }.joined(separator: " | ")
            let channels = sample.channels.map {
                "\($0.name):\($0.kind.rawValue)=\(Self.number($0.value))"
            }.joined(separator: " | ")
            return [
                formatter.string(from: sample.date),
                record.marker.rawValue,
                sample.percent.map { String($0) } ?? "",
                sample.externalConnected ? "1" : "0",
                sample.isCharging ? "1" : "0",
                estimate.mode.rawValue,
                estimate.sourceName,
                estimate.watts.map(Self.number) ?? "",
                estimate.rawWatts.map(Self.number) ?? "",
                estimate.voltage.map(Self.number) ?? "",
                estimate.current.map(Self.number) ?? "",
                estimate.confidence.rawValue,
                sample.batteryTemperature.map(Self.number) ?? "",
                sample.thermalState,
                candidates,
                channels,
            ].map(Self.csv).joined(separator: ",")
        }

        do {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("PowerLab-\(Int(Date.now.timeIntervalSince1970)).csv")
            try rows.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            exportURL = url
            lastError = nil
        } catch {
            exportURL = nil
            lastError = error.localizedDescription
        }
    }

    func startLoadTest(seconds: Int = 30) {
        guard !isLoadTestRunning else { return }
        stopLoadTest()
        marker = .cpuLoad
        loadTestRemaining = seconds
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))

        for seed in 1...2 {
            loadWorkers.append(Task.detached(priority: .userInitiated) {
                var value = UInt64(seed)
                while !Task.isCancelled, ContinuousClock.now < deadline {
                    for _ in 0..<150_000 {
                        value = value &* 2_862_933_555_777_941_757 &+ 3_037_000_493
                        value ^= value >> 17
                    }
                    await Task.yield()
                }
                _ = value
            })
        }

        loadCountdownTask = Task { [weak self] in
            guard let self else { return }
            for remaining in stride(from: seconds, through: 1, by: -1) {
                guard !Task.isCancelled else { return }
                loadTestRemaining = remaining
                try? await Task.sleep(for: .seconds(1))
            }
            stopLoadTest()
        }
    }

    func stopLoadTest() {
        loadWorkers.forEach { $0.cancel() }
        loadWorkers.removeAll()
        loadCountdownTask?.cancel()
        loadCountdownTask = nil
        loadTestRemaining = 0
    }

    private static func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(4)))
    }

    private static func csv(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
