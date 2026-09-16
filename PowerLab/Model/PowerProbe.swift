import Foundation

nonisolated struct RawField: Identifiable, Hashable, Codable, Sendable {
    let group: String
    let key: String
    let value: String
    var id: String { "\(group)#\(key)" }
}

nonisolated struct ChannelReading: Identifiable, Hashable, Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case voltage
        case current
        case temperature
        case other
    }

    let id: String
    let name: String
    let kind: Kind
    let value: Double
}

nonisolated struct PowerCandidate: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let name: String
    let voltage: Double
    let current: Double
    let detail: String

    var signedWatts: Double { voltage * current }
    var magnitudeWatts: Double { abs(signedWatts) }

    var isPlausibleBatteryOutput: Bool {
        (2.5...5.0).contains(voltage)
            && abs(current) >= 0.003
            && abs(current) <= 8
            && magnitudeWatts <= 35
    }
}

nonisolated struct ProbeSample: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    let date: Date
    let percent: Int?
    let externalConnected: Bool
    let isCharging: Bool
    let thermalState: String
    let batteryTemperature: Double?
    let channels: [ChannelReading]
    let candidates: [PowerCandidate]
    let rawFields: [RawField]
}

nonisolated enum SensorMode: String, CaseIterable, Identifiable, Sendable {
    case hidOnly = "HID 功耗模式"
    case ioKitOnly = "IOKit 诊断模式"
    case full = "IOKit + HID 完整模式"

    var id: Self { self }
}

@MainActor
final class PowerProbe {
    let mode: SensorMode
    private let battery: IOKitBattery?
    private let sensors: HIDSensors?
    private var sampleIndex = 0

    init(mode: SensorMode) {
        self.mode = mode

        if mode != .hidOnly {
            Self.recordStartupStage("正在创建 IOKit 电池接口")
            battery = IOKitBattery()
            Self.recordStartupStage(battery == nil ? "IOKit 接口不可用" : "IOKit 接口已创建")
        } else {
            battery = nil
            Self.recordStartupStage("已绕过 IOKit")
        }

        if mode != .ioKitOnly {
            Self.recordStartupStage("正在创建 HID 传感器接口")
            sensors = HIDSensors()
            Self.recordStartupStage(sensors == nil ? "HID 接口不可用" : "HID 接口已创建")
        } else {
            sensors = nil
            Self.recordStartupStage("IOKit 诊断模式已就绪（未创建 HID）")
        }
    }

    var status: String {
        switch (battery != nil, sensors != nil) {
        case (true, true): "IOKit 与 HID 均可用"
        case (true, false): "仅 IOKit 可用"
        case (false, true): "仅 HID 可用"
        case (false, false): "电源接口不可用"
        }
    }

    private static func recordStartupStage(_ stage: String) {
        UserDefaults.standard.set(stage, forKey: "PowerLabLastStartupStage")
        UserDefaults.standard.synchronize()
    }

    func capture() -> ProbeSample {
        sampleIndex += 1
        if sampleIndex == 1 || sampleIndex.isMultiple(of: 10) {
            if sampleIndex == 1 { Self.recordStartupStage("正在枚举 HID 传感器") }
            sensors?.rescan()
        }

        if sampleIndex == 1 { Self.recordStartupStage("正在读取 IOKit 注册表") }
        let registry = battery?.readRegistryProperties() ?? [:]
        if sampleIndex == 1 { Self.recordStartupStage("正在读取 powerd 电源数据") }
        let powerSources = battery?.readPowerSources() ?? []
        let powerSource = preferredPowerSource(powerSources)
        if sampleIndex == 1 { Self.recordStartupStage("正在读取 HID 传感器数值") }
        let hid = sensors?.read() ?? []
        if sampleIndex == 1 { Self.recordStartupStage("首次采样完成") }

        let percent = integer(["CurrentCapacity", "Current Capacity"], registry, powerSource)
        let externalConnected = boolean("ExternalConnected", in: registry)
            ?? ((powerSource["Power Source State"] as? String) == "AC Power")
            ?? boolean("Raw External Connected", in: powerSource)
            ?? false
        let isCharging = boolean("IsCharging", in: registry)
            ?? boolean("Is Charging", in: powerSource)
            ?? false

        let channels = hid.map { reading in
            ChannelReading(
                id: reading.id,
                name: reading.name,
                kind: channelKind(reading.kind),
                value: reading.value
            )
        }

        let candidates = makeCandidates(registry: registry, powerSource: powerSource, hid: hid)
        let batteryTemperature = hid.first {
            $0.kind == .temperature
                && $0.name.localizedCaseInsensitiveContains("battery")
                && (-40...150).contains($0.value)
        }?.value

        return ProbeSample(
            id: UUID(),
            date: .now,
            percent: percent,
            externalConnected: externalConnected,
            isCharging: isCharging,
            thermalState: Self.thermalStateName(ProcessInfo.processInfo.thermalState),
            batteryTemperature: batteryTemperature,
            channels: channels,
            candidates: candidates,
            rawFields: rawFields(registry: registry, powerSources: powerSources)
        )
    }

    private func makeCandidates(
        registry: [String: Any],
        powerSource: [String: Any],
        hid: [HIDSensors.Reading]
    ) -> [PowerCandidate] {
        var result: [PowerCandidate] = []

        if let voltage = millivolts("Voltage", in: registry),
           let current = milliamps(["InstantAmperage", "Amperage", "AvgAmperage"], in: registry) {
            result.append(PowerCandidate(
                id: "registry",
                name: "IORegistry 电池",
                voltage: voltage,
                current: current,
                detail: "Voltage × InstantAmperage"
            ))
        }

        if let voltage = millivolts(["Voltage", "AppleRawVoltage"], in: powerSource),
           let current = milliamps(["InstantAmperage", "Amperage", "Avg Amperage"], in: powerSource) {
            result.append(PowerCandidate(
                id: "powerd",
                name: "powerd 电池",
                voltage: voltage,
                current: current,
                detail: "电源描述字典"
            ))
        }

        let voltageReadings = hid.filter { $0.kind == .voltage }
        let currentReadings = hid.filter { $0.kind == .current }

        func exact(_ name: String, in readings: [HIDSensors.Reading]) -> HIDSensors.Reading? {
            readings.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        }
        func containing(_ fragments: [String], in readings: [HIDSensors.Reading]) -> HIDSensors.Reading? {
            readings.first { reading in
                fragments.contains { reading.name.localizedCaseInsensitiveContains($0) }
            }
        }

        let batteryVoltage = exact("Charger VQ0l", in: voltageReadings)
            ?? exact("PMU VP0u", in: voltageReadings)
            ?? containing(["VQ0l", "VP0u", "battery"], in: voltageReadings)
        let batteryCurrent = exact("Charger IQ0B", in: currentReadings)
            ?? containing(["IQ0B", "battery"], in: currentReadings)
        if let batteryVoltage, let batteryCurrent {
            result.append(PowerCandidate(
                id: "hid-battery-rail",
                name: "HID 电池轨",
                voltage: batteryVoltage.value,
                current: batteryCurrent.value,
                detail: "\(batteryVoltage.name) × \(batteryCurrent.name)"
            ))
        }

        let voltagesByRail = Dictionary(grouping: voltageReadings, by: { railKey($0.name, kind: .voltage) })
        let currentsByRail = Dictionary(grouping: currentReadings, by: { railKey($0.name, kind: .current) })
        for rail in Set(voltagesByRail.keys).intersection(currentsByRail.keys).sorted() {
            guard !rail.isEmpty,
                  let voltage = voltagesByRail[rail]?.first,
                  let current = currentsByRail[rail]?.first
            else { continue }
            result.append(PowerCandidate(
                id: "hid-pair-\(rail)",
                name: "HID 配对 · \(rail)",
                voltage: voltage.value,
                current: current.value,
                detail: "\(voltage.name) × \(current.name)"
            ))
        }

        var seen: Set<String> = []
        return result.filter { seen.insert($0.id).inserted }
    }

    private func preferredPowerSource(_ sources: [[String: Any]]) -> [String: Any] {
        sources.first {
            ($0["Type"] as? String)?.localizedCaseInsensitiveContains("internal") == true
                || ($0["Name"] as? String)?.localizedCaseInsensitiveContains("battery") == true
        } ?? sources.first ?? [:]
    }

    private func rawFields(registry: [String: Any], powerSources: [[String: Any]]) -> [RawField] {
        var fields = registry.map { key, value in
            RawField(group: "IORegistry", key: key, value: Self.describe(value))
        }
        for (index, source) in powerSources.enumerated() {
            fields += source.map { key, value in
                RawField(group: "powerd[\(index)]", key: key, value: Self.describe(value))
            }
        }
        return fields.sorted { ($0.group, $0.key) < ($1.group, $1.key) }
    }

    private func railKey(_ name: String, kind: HIDSensors.Kind) -> String {
        var key = name.lowercased()
        switch kind {
        case .current:
            key = key.replacingOccurrences(of: "iq", with: "q")
            key = key.replacingOccurrences(of: "ip", with: "p")
            key = key.replacingOccurrences(of: "current", with: "")
        case .voltage:
            key = key.replacingOccurrences(of: "vq", with: "q")
            key = key.replacingOccurrences(of: "vp", with: "p")
            key = key.replacingOccurrences(of: "voltage", with: "")
        default:
            break
        }
        return key
            .split { !$0.isLetter && !$0.isNumber }
            .joined(separator: "-")
    }

    private func channelKind(_ kind: HIDSensors.Kind) -> ChannelReading.Kind {
        switch kind {
        case .voltage: .voltage
        case .current: .current
        case .temperature: .temperature
        case .other: .other
        }
    }

    private func integer(
        _ keys: [String],
        _ first: [String: Any],
        _ second: [String: Any]
    ) -> Int? {
        for key in keys {
            if let value = first[key] as? NSNumber { return value.intValue }
            if let value = second[key] as? NSNumber { return value.intValue }
        }
        return nil
    }

    private func boolean(_ key: String, in dictionary: [String: Any]) -> Bool? {
        (dictionary[key] as? NSNumber)?.boolValue
    }

    private func millivolts(_ key: String, in dictionary: [String: Any]) -> Double? {
        millivolts([key], in: dictionary)
    }

    private func millivolts(_ keys: [String], in dictionary: [String: Any]) -> Double? {
        for key in keys where dictionary[key] != nil {
            if let number = dictionary[key] as? NSNumber {
                let value = number.doubleValue
                return abs(value) > 100 ? value / 1000 : value
            }
        }
        return nil
    }

    private func milliamps(_ keys: [String], in dictionary: [String: Any]) -> Double? {
        for key in keys where dictionary[key] != nil {
            if let number = dictionary[key] as? NSNumber {
                let value = number.doubleValue
                return abs(value) > 20 ? value / 1000 : value
            }
        }
        return nil
    }

    private static func describe(_ value: Any) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        return String(describing: value)
    }

    private static func thermalStateName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "正常"
        case .fair: "轻微"
        case .serious: "严重"
        case .critical: "临界"
        @unknown default: "未知"
        }
    }
}
