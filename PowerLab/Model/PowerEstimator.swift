import Foundation

nonisolated enum EstimateConfidence: String, Codable, Sendable {
    case high = "高"
    case medium = "中"
    case experimental = "待验证"
    case low = "低"
    case none = "无"
}

nonisolated enum EstimateMode: String, Codable, Sendable {
    case measured = "传感器实测"
    case averaged = "电量变化平均估算"
    case calibrating = "正在收集数据"
    case externalPower = "已连接外部电源"
}

nonisolated struct PowerEstimate: Hashable, Codable, Sendable {
    let date: Date
    let mode: EstimateMode
    let watts: Double?
    let rawWatts: Double?
    let voltage: Double?
    let current: Double?
    let sourceID: String?
    let sourceName: String
    let confidence: EstimateConfidence
    let note: String
    let percentTransitions: Int
}

nonisolated struct PowerHistoryPoint: Identifiable, Hashable, Sendable {
    let date: Date
    let watts: Double
    let measured: Bool
    var id: Date { date }
}

/// Selects the strongest battery-output channel, rejects physically impossible
/// values, median-filters five one-second samples, then applies a three-second
/// exponential smoother. If no current channel survives, it falls back to an
/// explicitly labelled multi-percent average instead of inventing watts from
/// voltage alone.
@MainActor
final class PowerEstimator {
    private struct PercentPoint {
        let date: Date
        let percent: Int
    }

    private var candidateHistory: [String: [(Date, Double)]] = [:]
    private var recentAvailability: [Set<String>] = []
    private var percentPoints: [PercentPoint] = []
    private var wasExternal: Bool?
    private var smoothedWatts: Double?
    private var smoothedSourceID: String?
    private var lastSmoothedAt: Date?

    func ingest(_ sample: ProbeSample, capacityWh: Double) -> PowerEstimate {
        updateAvailability(sample)
        updatePercentHistory(sample)

        guard !sample.externalConnected else {
            resetSmoother()
            return PowerEstimate(
                date: sample.date,
                mode: .externalPower,
                watts: nil,
                rawWatts: nil,
                voltage: nil,
                current: nil,
                sourceID: nil,
                sourceName: "请拔掉充电器",
                confidence: .none,
                note: "充电时电池轨功率不等于整机功耗，本轮实验只验证放电功耗。",
                percentTransitions: max(percentPoints.count - 1, 0)
            )
        }

        if let candidate = selectCandidate(sample.candidates) {
            let raw = candidate.magnitudeWatts
            var history = candidateHistory[candidate.id, default: []]
            history.append((sample.date, raw))
            if history.count > 12 { history.removeFirst(history.count - 12) }
            candidateHistory[candidate.id] = history

            let median = Self.median(history.suffix(5).map { $0.1 })
            let filtered = smooth(median, sourceID: candidate.id, date: sample.date)
            let availability = availabilityRatio(candidate.id)
            let confidence = confidence(for: candidate, availability: availability)
            let sign = candidate.current < 0 ? "电流负号与放电方向一致" : "电流为正，需用负载测试确认方向"

            return PowerEstimate(
                date: sample.date,
                mode: .measured,
                watts: filtered,
                rawWatts: raw,
                voltage: candidate.voltage,
                current: candidate.current,
                sourceID: candidate.id,
                sourceName: candidate.name,
                confidence: confidence,
                note: "\(sign)；最近 30 个样本可用率 \(Int(availability * 100))%。",
                percentTransitions: max(percentPoints.count - 1, 0)
            )
        }

        resetSmoother()
        if let average = percentageAverageWatts(capacityWh: capacityWh) {
            return PowerEstimate(
                date: sample.date,
                mode: .averaged,
                watts: average,
                rawWatts: nil,
                voltage: preferredVoltage(sample.channels),
                current: nil,
                sourceID: nil,
                sourceName: "电量百分比斜率",
                confidence: .low,
                note: "这是跨越多个 1% 电量变化的平均值，不是每秒实时功耗。",
                percentTransitions: max(percentPoints.count - 1, 0)
            )
        }

        return PowerEstimate(
            date: sample.date,
            mode: .calibrating,
            watts: nil,
            rawWatts: nil,
            voltage: preferredVoltage(sample.channels),
            current: nil,
            sourceID: nil,
            sourceName: "尚未找到可用放电电流",
            confidence: .none,
            note: "需要至少 3 次完整的 1% 电量变化，才能给出分钟级平均估算。",
            percentTransitions: max(percentPoints.count - 1, 0)
        )
    }

    private func selectCandidate(_ candidates: [PowerCandidate]) -> PowerCandidate? {
        let valid = candidates.filter(\.isPlausibleBatteryOutput)
        let order = ["registry", "powerd", "hid-battery-rail"]
        for id in order {
            if let candidate = valid.first(where: { $0.id == id }) { return candidate }
        }
        return valid.first { candidate in
            let text = (candidate.name + " " + candidate.detail).lowercased()
            return text.contains("battery")
                || text.contains("电池")
                || text.contains("iq0b")
                || text.contains("vq0l")
                || text.contains("vp0u")
        }
    }

    private func updateAvailability(_ sample: ProbeSample) {
        recentAvailability.append(Set(sample.candidates.filter(\.isPlausibleBatteryOutput).map(\.id)))
        if recentAvailability.count > 30 {
            recentAvailability.removeFirst(recentAvailability.count - 30)
        }
    }

    private func availabilityRatio(_ id: String) -> Double {
        guard !recentAvailability.isEmpty else { return 0 }
        let available = recentAvailability.filter { $0.contains(id) }.count
        return Double(available) / Double(recentAvailability.count)
    }

    private func confidence(for candidate: PowerCandidate, availability: Double) -> EstimateConfidence {
        guard recentAvailability.count >= 10 else { return .experimental }
        if candidate.id == "registry", candidate.current < 0, availability >= 0.9 { return .high }
        if availability >= 0.85 { return .medium }
        return .experimental
    }

    private func smooth(_ value: Double, sourceID: String, date: Date) -> Double {
        guard smoothedSourceID == sourceID,
              let previous = smoothedWatts,
              let lastDate = lastSmoothedAt
        else {
            smoothedSourceID = sourceID
            smoothedWatts = value
            lastSmoothedAt = date
            return value
        }

        let interval = max(date.timeIntervalSince(lastDate), 0.001)
        let alpha = 1 - exp(-interval / 3)
        let next = previous + alpha * (value - previous)
        smoothedWatts = next
        lastSmoothedAt = date
        return next
    }

    private func resetSmoother() {
        smoothedWatts = nil
        smoothedSourceID = nil
        lastSmoothedAt = nil
    }

    private func updatePercentHistory(_ sample: ProbeSample) {
        if wasExternal != sample.externalConnected {
            wasExternal = sample.externalConnected
            percentPoints.removeAll()
        }
        guard !sample.externalConnected, let percent = sample.percent else { return }
        if percentPoints.last?.percent != percent {
            percentPoints.append(PercentPoint(date: sample.date, percent: percent))
            if percentPoints.count > 8 { percentPoints.removeFirst(percentPoints.count - 8) }
        }
    }

    private func percentageAverageWatts(capacityWh: Double) -> Double? {
        // The first transition begins mid-percent. Discard it, then require two
        // complete transitions, matching MiniWatts' conservative fallback.
        let points = Array(percentPoints.dropFirst())
        guard points.count >= 3, capacityWh > 0 else { return nil }

        let origin = points[0].date
        let xs = points.map { $0.date.timeIntervalSince(origin) }
        let ys = points.map { Double($0.percent) }
        let meanX = xs.reduce(0, +) / Double(xs.count)
        let meanY = ys.reduce(0, +) / Double(ys.count)
        let numerator = zip(xs, ys).reduce(0.0) { partial, pair in
            partial + (pair.0 - meanX) * (pair.1 - meanY)
        }
        let denominator = xs.reduce(0.0) { $0 + pow($1 - meanX, 2) }
        guard denominator > 0 else { return nil }
        let percentPerSecond = numerator / denominator
        guard percentPerSecond < 0 else { return nil }
        return -percentPerSecond / 100 * capacityWh * 3600
    }

    private func preferredVoltage(_ channels: [ChannelReading]) -> Double? {
        let voltages = channels.filter { $0.kind == .voltage && (2.5...5.0).contains($0.value) }
        return voltages.first {
            let name = $0.name.lowercased()
            return name.contains("vq0l") || name.contains("vp0u") || name.contains("battery")
        }?.value ?? voltages.first?.value
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        if sorted.count.isMultiple(of: 2) {
            let upper = sorted.count / 2
            return (sorted[upper - 1] + sorted[upper]) / 2
        }
        return sorted[sorted.count / 2]
    }
}
