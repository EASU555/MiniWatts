import Charts
import SwiftUI

struct PowerLabRootView: View {
    var body: some View {
        TabView {
            LivePowerView()
                .tabItem { Label("实时", systemImage: "bolt.fill") }
            SensorChannelsView()
                .tabItem { Label("通道", systemImage: "waveform.path.ecg") }
            PowerTestView()
                .tabItem { Label("测试", systemImage: "testtube.2") }
        }
        .tint(.cyan)
    }
}

private struct LivePowerView: View {
    @Environment(PowerLabMonitor.self) private var monitor

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    powerHero
                    if !monitor.history.isEmpty { historyChart }
                    electricalDetails
                    explanation
                }
                .padding()
            }
            .navigationTitle("PowerLab")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { VersionBadge() }
            }
            .refreshable { monitor.sampleNow() }
        }
    }

    private var powerHero: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    if let watts = monitor.estimate?.watts {
                        Text(watts.formatted(.number.precision(.fractionLength(2))))
                            .font(.system(.largeTitle, design: .rounded, weight: .bold))
                            .monospacedDigit()
                        Text("W")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("—")
                            .font(.system(.largeTitle, design: .rounded, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let estimate = monitor.estimate {
                        ConfidenceBadge(confidence: estimate.confidence)
                    }
                }

                Text(monitor.estimate?.mode.rawValue ?? "正在启动探测器")
                    .font(.headline)
                Text(monitor.estimate?.sourceName ?? monitor.probeStatus)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let note = monitor.estimate?.note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("放电功耗", systemImage: "battery.50percent")
        }
    }

    private var historyChart: some View {
        GroupBox {
            Chart(Array(monitor.history.suffix(180))) { point in
                LineMark(
                    x: .value("时间", point.date),
                    y: .value("功率", point.watts)
                )
                .foregroundStyle(point.measured ? Color.cyan : Color.orange)
                .interpolationMethod(.catmullRom)
            }
            .chartXAxis(.hidden)
            .chartYAxisLabel("W")
            .frame(height: 180)
            .accessibilityLabel("最近三分钟功耗曲线")
        } label: {
            Label("最近三分钟", systemImage: "chart.xyaxis.line")
        }
    }

    private var electricalDetails: some View {
        GroupBox {
            VStack(spacing: 8) {
                metricRow("电池电量", value: monitor.latestSample?.percent.map { "\($0)%" } ?? "—")
                metricRow("电池电压", value: formatted(monitor.estimate?.voltage, unit: "V"))
                metricRow("电池电流", value: formatted(monitor.estimate?.current, unit: "A"))
                metricRow("电池温度", value: formatted(monitor.latestSample?.batteryTemperature, unit: "°C"))
                metricRow("系统发热", value: monitor.latestSample?.thermalState ?? "—")
                metricRow("采样周期", value: "1 秒")
                metricRow("电量变化次数", value: "\(monitor.estimate?.percentTransitions ?? 0)")
            }
        } label: {
            Label("本次读数", systemImage: "gauge.with.dots.needle.50percent")
        }
    }

    private var explanation: some View {
        GroupBox {
            Text("蓝色曲线来自电压×电流的传感器测量；橙色曲线是跨多个电量百分比变化得到的分钟级平均估算。PowerLab 不会只凭电压生成实时瓦数。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("判读规则", systemImage: "info.circle")
        }
    }

    private func metricRow(_ title: String, value: String) -> some View {
        LabeledContent(title) {
            Text(value).monospacedDigit()
        }
    }

    private func formatted(_ value: Double?, unit: String) -> String {
        guard let value else { return "—" }
        return value.formatted(.number.precision(.fractionLength(3))) + " " + unit
    }
}

private struct SensorChannelsView: View {
    @Environment(PowerLabMonitor.self) private var monitor

    private var candidates: [PowerCandidate] { monitor.latestSample?.candidates ?? [] }
    private var voltages: [ChannelReading] {
        monitor.latestSample?.channels.filter { $0.kind == .voltage } ?? []
    }
    private var currents: [ChannelReading] {
        monitor.latestSample?.channels.filter { $0.kind == .current } ?? []
    }

    var body: some View {
        NavigationStack {
            List {
                Section("候选功率通道") {
                    if candidates.isEmpty {
                        ContentUnavailableView(
                            "没有可配对的电压与电流",
                            systemImage: "bolt.slash",
                            description: Text("保持 App 在前台并拔掉充电器继续观察。")
                        )
                    } else {
                        ForEach(candidates) { candidate in
                            CandidateRow(
                                candidate: candidate,
                                selected: candidate.id == monitor.estimate?.sourceID
                            )
                        }
                    }
                }

                Section("电压传感器") {
                    channelRows(voltages, unit: "V")
                }
                Section("电流传感器") {
                    channelRows(currents, unit: "A")
                }

                if let fields = monitor.latestSample?.rawFields, !fields.isEmpty {
                    Section("IOKit / powerd 原始字段") {
                        NavigationLink("查看全部 \(fields.count) 项") {
                            RawFieldsView(fields: fields)
                        }
                    }
                }
            }
            .navigationTitle("传感器通道")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("刷新", systemImage: "arrow.clockwise") { monitor.sampleNow() }
                }
            }
        }
    }

    @ViewBuilder
    private func channelRows(_ channels: [ChannelReading], unit: String) -> some View {
        if channels.isEmpty {
            Text("未发现")
                .foregroundStyle(.secondary)
        } else {
            ForEach(channels) { channel in
                LabeledContent(channel.name) {
                    Text(channel.value.formatted(.number.precision(.fractionLength(4))) + " " + unit)
                        .font(.callout.monospacedDigit())
                }
            }
        }
    }
}

private struct CandidateRow: View {
    let candidate: PowerCandidate
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(candidate.name)
                    .font(.headline)
                Spacer()
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.cyan)
                        .accessibilityLabel("当前选中")
                }
            }
            Text(candidate.signedWatts.formatted(.number.precision(.fractionLength(3))) + " W")
                .font(.title3.monospacedDigit().weight(.semibold))
            Text(
                candidate.voltage.formatted(.number.precision(.fractionLength(4)))
                    + " V × "
                    + candidate.current.formatted(.number.precision(.fractionLength(4)))
                    + " A"
            )
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            Text(candidate.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct RawFieldsView: View {
    let fields: [RawField]

    var body: some View {
        List(fields) { field in
            VStack(alignment: .leading, spacing: 4) {
                Text("\(field.group) · \(field.key)")
                    .font(.headline)
                Text(field.value)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        }
        .navigationTitle("原始字段")
    }
}

private struct PowerTestView: View {
    @Environment(PowerLabMonitor.self) private var monitor

    var body: some View {
        @Bindable var monitor = monitor
        NavigationStack {
            Form {
                Section("测试记录") {
                    Picker("当前场景", selection: $monitor.marker) {
                        ForEach(TestMarker.allCases) { marker in
                            Text(marker.rawValue).tag(marker)
                        }
                    }

                    Button {
                        monitor.isRecording ? monitor.stopRecording() : monitor.startRecording()
                    } label: {
                        Label(
                            monitor.isRecording ? "停止并生成 CSV" : "开始新记录",
                            systemImage: monitor.isRecording ? "stop.circle.fill" : "record.circle"
                        )
                    }
                    .tint(monitor.isRecording ? .red : .cyan)

                    LabeledContent("已记录样本", value: "\(monitor.recordedSamples.count)")

                    if let exportURL = monitor.exportURL {
                        ShareLink(item: exportURL) {
                            Label("导出 CSV", systemImage: "square.and.arrow.up")
                        }
                    }

                    if !monitor.recordedSamples.isEmpty {
                        Button("清除记录", role: .destructive) { monitor.clearRecording() }
                    }
                }

                Section("受控负载") {
                    if monitor.isLoadTestRunning {
                        Button("停止 CPU 负载（剩余 \(monitor.loadTestRemaining) 秒）", role: .destructive) {
                            monitor.stopLoadTest()
                        }
                        ProgressView(value: Double(30 - monitor.loadTestRemaining), total: 30)
                    } else {
                        Button {
                            if !monitor.isRecording { monitor.startRecording() }
                            monitor.startLoadTest()
                        } label: {
                            Label("运行 30 秒 CPU 负载", systemImage: "cpu")
                        }
                    }

                    Text("先记录约两分钟待机基线，再运行负载测试。如果候选电流和瓦数同步上升，说明该通道有希望用于实时功耗。系统进入“严重”或“临界”发热状态时会自动停止。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("估算参数") {
                    Stepper(value: $monitor.capacityWh, in: 5...30, step: 0.1) {
                        LabeledContent("电池额定能量") {
                            Text(monitor.capacityWh.formatted(.number.precision(.fractionLength(1))) + " Wh")
                                .monospacedDigit()
                        }
                    }
                    Text("只在没有放电电流传感器时用于百分比速率估算。不会影响传感器实测值。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("实验说明") {
                    Label(monitor.probeStatus, systemImage: "checkmark.seal")
                    Text("测试期间保持 PowerLab 在前台并拔掉充电器。这个实验包与 MiniWatts 使用不同的 Bundle ID，可以同时安装。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let error = monitor.lastError {
                        Text(error).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("实机测试")
        }
    }
}

private struct ConfidenceBadge: View {
    let confidence: EstimateConfidence

    var body: some View {
        Text(confidence.rawValue)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
            .accessibilityLabel("置信度 \(confidence.rawValue)")
    }

    private var color: Color {
        switch confidence {
        case .high: .green
        case .medium: .cyan
        case .experimental: .orange
        case .low: .yellow
        case .none: .secondary
        }
    }
}

private struct VersionBadge: View {
    var body: some View {
        Text(verbatim: "v\(version) (\(build))")
            .font(.caption2.monospaced().weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityLabel("PowerLab 版本 \(version)，构建 \(build)")
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }
}
