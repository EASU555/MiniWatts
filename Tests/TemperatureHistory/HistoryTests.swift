import Foundation

@main @MainActor struct TemperatureHistoryTests {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) { precondition(condition(), message) }
    static func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }
    static func reading(_ value: Double?, source: String? = "battery-A") -> [TemperatureComponent: TemperatureObservation] {
        [.batteryTemperature: TemperatureObservation(value: value, source: source)]
    }
    static func frame(_ seconds: Double, _ value: Double?, start: Bool = false) -> TemperatureHistoryRecord {
        TemperatureHistoryRecord(date: date(seconds), values: value.map { [TemperatureComponent.batteryTemperature.rawValue: $0] } ?? [:],
                                 startsNewSegment: start, sourceBreaks: nil)
    }
    static func saved(_ result: TemperatureHistoryStore.SaveResult) {
        guard case .saved = result else { preconditionFailure("Both copies must save") }
    }
    static func waitForSave(_ store: TemperatureHistoryStore, count: Int) async {
        for _ in 0..<100 {
            if case .loaded(let records) = await store.loaded(), records.count == count { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        preconditionFailure("A queued controller write did not finish")
    }
    static func main() async throws {
        var recorder = TemperatureHistoryRecorder()
        for second in 0...15 { recorder.observe(date: date(Double(second)), readings: reading(35 + Double(second) / 100)) }
        check(recorder.records.map(\.date) == [0, 5, 10, 15].map { date(Double($0)) },
              "History did not use five-second frames")
        check(recorder.records.first?.startsNewSegment == true, "A new process joined an old segment")
        recorder.observe(date: date(16), readings: reading(nil))
        recorder.observe(date: date(17), readings: reading(36))
        recorder.observe(date: date(20), readings: reading(36))
        check(recorder.records.last?.sourceBreaks?.contains(TemperatureComponent.batteryTemperature.rawValue) == true,
              "An interruption between stored frames disappeared")
        recorder.observe(date: date(21), readings: reading(36, source: "battery-B"))
        recorder.observe(date: date(25), readings: reading(36, source: "battery-B"))
        check(recorder.records.last?.sourceBreaks?.contains(TemperatureComponent.batteryTemperature.rawValue) == true,
              "Changing source retained a connecting line")
        recorder.breakContinuity()
        recorder.observe(date: date(30), readings: reading(37))
        check(recorder.records.last?.startsNewSegment == true, "Explicit pause did not break the next frame")
        check(!recorder.observe(date: date(30), readings: reading(80)), "Duplicate timestamp was appended")
        recorder.observe(date: date(40), readings: reading(37))
        check(recorder.records.last?.startsNewSegment == true, "Long sample gap was not marked")
        recorder.observe(date: date(90_000), readings: reading(38))
        check(recorder.records.count == 1, "Frames older than 24 hours were retained")
        var empty = TemperatureHistoryRecorder()
        check(!empty.observe(date: date(0), readings: reading(nil)), "Missing readings created a zero curve")
        check(!empty.observe(date: date(1), readings: reading(.nan)), "NaN became a stored temperature")
        check(empty.observe(date: date(5), readings: reading(0)), "A real zero was treated as missing")
        print("PASS: cadence, inter-frame dropouts, source changes, pause, duplicates, retention and missing vs zero")

        let broken = [frame(0, 30, start: true), frame(5, 31), frame(10, nil), frame(15, 33),
                      frame(20, 34, start: true), frame(1000, 40)]
        let gaps = TemperatureCurvePlot.make(records: broken, component: .batteryTemperature, range: .hour, compare: false)
        check(gaps.points[0].series == gaps.points[1].series, "Continuous points were split")
        check(gaps.points[1].series != gaps.points[2].series, "Missing data was bridged")
        check(gaps.points[2].series != gaps.points[3].series, "An explicit pause was bridged")
        check(gaps.points[3].series != gaps.points[4].series, "A large time gap was bridged")
        check(gaps.nearest(to: date(500)) == nil, "Gap selection snapped to an unrelated reading")
        check(gaps.nearest(to: date(16))?.value(.batteryTemperature) == 33, "Selection did not resolve an actual nearby frame")
        check(gaps.singletons.count == 3, "Isolated observations became invisible")
        check(gaps.summaries[.batteryTemperature]?.maximum == 40, "Summary maximum is wrong")
        let emptyPlot = TemperatureCurvePlot.make(records: [], component: .socTemperature, range: .day, compare: true)
        check(emptyPlot.points.isEmpty && emptyPlot.summaries.isEmpty, "An empty history invented temperatures")
        var dense: [TemperatureHistoryRecord] = []
        for index in 0..<2_000 {
            let value = index == 777 ? 99.0 : index == 888 ? 19 : 35 + sin(Double(index) / 20)
            dense.append(frame(Double(index * 5), value))
        }
        let reduced = TemperatureCurvePlot.make(records: dense, component: .batteryTemperature, range: .sixHours, compare: false)
        check(reduced.points.count <= 256, "Long chart mark count is not bounded")
        check(reduced.points.contains { $0.value == 99 } && reduced.points.contains { $0.value == 19 },
              "Drawing reduction erased a peak or valley")
        check(reduced.summaries[.batteryTemperature]?.count == 2000, "Statistics used the reduced drawing points")
        check(reduced.points.map(\.date) == reduced.points.map(\.date).sorted(), "Reduction reordered extrema")
        let churn = dense.map { TemperatureHistoryRecord(date: $0.date, values: $0.values, startsNewSegment: true, sourceBreaks: nil) }
        let bounded = TemperatureCurvePlot.make(records: churn, component: .batteryTemperature, range: .sixHours, compare: false)
        check(bounded.points.count <= 256 && bounded.singletons.count == bounded.points.count,
              "Hard-cap reduction invented lines across discarded segments")
        print("PASS: curve gaps, point selection, isolated points, truthful statistics, peak/valley reduction and hard caps")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("temperature-tests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TemperatureHistoryStore(directory: root)
        guard case .loaded(let first) = await store.loaded(), first.isEmpty else { preconditionFailure("First launch must be empty") }
        saved(await store.save(broken))
        let primary = root.appendingPathComponent("temperature-history-v1.json")
        let backup = root.appendingPathComponent("temperature-history-v1.json.backup")
        let beforeAppend = try Data(contentsOf: primary)
        let appended = broken + [frame(1005, 41)]
        saved(await store.save(appended))
        let afterAppend = try Data(contentsOf: primary)
        check(afterAppend.starts(with: beforeAppend) && afterAppend.count > beforeAppend.count,
              "A small checkpoint rewrote the full history instead of appending")
        let torn = try FileHandle(forWritingTo: primary)
        try torn.seekToEnd()
        try torn.write(contentsOf: Data("{partial-tail".utf8))
        try torn.close()
        guard case .recovered(let completeBatch, _) = await store.loaded(), completeBatch == appended else {
            preconditionFailure("A torn append was accepted or could not recover its complete safety copy")
        }
        try Data("damaged-primary".utf8).write(to: primary, options: .atomic)
        guard case .recovered(let recovered, _) = await store.loaded(), recovered == appended else {
            preconditionFailure("Safety-copy recovery failed")
        }
        try Data("damaged-backup".utf8).write(to: backup, options: .atomic)
        guard case .failed = await store.loaded() else { preconditionFailure("Two corrupt copies became empty history") }
        let failedController = TemperatureHistoryController(store: store)
        await failedController.load()
        failedController.record(PowerSnapshot(), rates: [:])
        failedController.persist()
        check(failedController.storageState == .loadFailed, "Failed load was hidden")
        let stillDamaged = try String(contentsOf: primary, encoding: .utf8)
        check(stillDamaged == "damaged-primary", "Failed load allowed destructive overwrite")
        saved(await store.save([]))
        guard case .loaded(let cleared) = await store.loaded(), cleared.isEmpty else { preconditionFailure("Clear did not save") }
        let emptyBackup = try Data(contentsOf: backup)
        let emptyPrimary = try Data(contentsOf: primary)
        check(emptyPrimary == emptyBackup, "Clear did not replace both copies")
        print("PASS: incremental checkpoints, torn-append recovery, corrupt-file preservation and both-copy clear")

        let liveDirectory = root.appendingPathComponent("live")
        let liveStore = TemperatureHistoryStore(directory: liveDirectory)
        let oldDate = Date.now.addingTimeInterval(-120)
        let oldRecord = TemperatureHistoryRecord(date: oldDate, values: [TemperatureComponent.batteryTemperature.rawValue: 33],
                                                startsNewSegment: true, sourceBreaks: nil)
        saved(await liveStore.save([oldRecord]))
        let controller = TemperatureHistoryController(store: liveStore)
        let gauge = HIDSensors.Reading(name: "gas gauge battery", kind: .temperature, value: 36, index: 0)
        controller.record(PowerSnapshot(date: oldDate.addingTimeInterval(115), sensors: [gauge]), rates: [:])
        await controller.load()
        check(controller.records.count == 2, "Async loading erased a newly recorded temperature")
        await waitForSave(liveStore, count: 2)
        controller.pause()
        check(!controller.isRecording && controller.latestRates.isEmpty, "Paused history still claimed a current trend")
        controller.clear()
        await waitForSave(liveStore, count: 0)
        let restart = TemperatureHistoryController(store: liveStore)
        await restart.load()
        check(restart.records.isEmpty, "Deleted temperature history returned on restart")
        let blockedDirectory = root.appendingPathComponent("blocked")
        try Data([1]).write(to: blockedDirectory)
        guard case .failed = await TemperatureHistoryStore(directory: blockedDirectory).save(broken) else {
            preconditionFailure("An unwritable directory reported success")
        }
        print("PASS: load/live merge, serialized controller saves, paused status, clear/restart and write failures")
    }
}
