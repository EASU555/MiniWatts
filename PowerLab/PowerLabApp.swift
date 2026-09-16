import SwiftUI

@main
struct PowerLabApp: App {
    var body: some Scene {
        WindowGroup {
            PowerLabLauncherView()
        }
    }
}

private struct PowerLabLauncherView: View {
    @State private var selectedMode: SensorMode?

    var body: some View {
        if let selectedMode {
            PowerLabSessionView(mode: selectedMode) {
                self.selectedMode = nil
            }
        } else {
            NavigationStack {
                List {
                    Section {
                        Label("界面已正常启动", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        LabeledContent("上次传感器阶段", value: lastStartupStage)
                    } header: {
                        Text("启动诊断")
                    } footer: {
                        Text("此页面不会创建任何私有传感器。如果能看到这里，说明闪退来自后续传感器初始化，而不是应用图标或 SwiftUI 场景。")
                    }

                    Section("选择探测方式") {
                        Button {
                            selectedMode = .hidOnly
                        } label: {
                            Label("启动 HID 功耗模式（推荐）", systemImage: "waveform.path.ecg")
                        }

                        Button {
                            selectedMode = .ioKitOnly
                        } label: {
                            Label("测试 IOKit 崩溃点", systemImage: "exclamationmark.triangle")
                        }

                        Button {
                            selectedMode = .full
                        } label: {
                            Label("启动 IOKit + HID 完整模式", systemImage: "sensor.tag.radiowaves.forward")
                        }
                    }

                    Section("建议顺序") {
                        Text("请先打开 HID 功耗模式。它完全绕过刚才导致闪退的 IOKit，仍可读取 MiniWatts 使用的电压、电流和温度传感器。IOKit 选项只保留用于定位崩溃。")
                            .foregroundStyle(.secondary)
                    }
                }
                .navigationTitle("PowerLab 测试")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { VersionBadge() }
                }
            }
        }
    }

    private var lastStartupStage: String {
        UserDefaults.standard.string(forKey: "PowerLabLastStartupStage") ?? "尚未启动传感器"
    }
}

private struct PowerLabSessionView: View {
    @State private var monitor: PowerLabMonitor
    let exit: () -> Void

    init(mode: SensorMode, exit: @escaping () -> Void) {
        _monitor = State(initialValue: PowerLabMonitor(sensorMode: mode))
        self.exit = exit
    }

    var body: some View {
        PowerLabRootView(exit: exit)
            .environment(monitor)
            .task {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                monitor.start()
            }
    }
}
