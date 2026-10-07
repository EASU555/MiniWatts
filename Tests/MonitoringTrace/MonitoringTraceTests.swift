import Foundation

@main struct MonitoringTraceTests {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }

    static func at(_ second: TimeInterval) -> Date {
        Date(timeIntervalSince1970: second)
    }

    static func main() async throws {
        let sample = SampleTimingTrace(tick: 7, startedAt: at(10.125), cpuSampledAt: at(10.25),
                                       cpuIntervalSeconds: 1.25, finishedAt: at(10.75),
                                       publishedAt: at(11.5), elapsedMilliseconds: 625,
                                       cpuUsagePercent: 12.34)
        let expectedSample: String = "tick=7 start=10.125 cpuAt=10.250 cpuWindow=1.25s finish=10.750 publish=11.500 probeMs=625 cpu=12.3"
        check(sample.formatted == expectedSample, "Sample timing fields or precision changed")
        let missing = SampleTimingTrace(tick: 1, startedAt: at(0), cpuSampledAt: at(0),
                                        cpuIntervalSeconds: nil, finishedAt: at(1),
                                        publishedAt: at(2), elapsedMilliseconds: 1_000,
                                        cpuUsagePercent: nil)
        let expectedMissing: String = "tick=1 start=0.000 cpuAt=0.000 cpuWindow=—s finish=1.000 publish=2.000 probeMs=1000 cpu=nil"
        check(missing.formatted == expectedMissing, "Missing timing data was replaced with zero")

        let activity = ActivityTimingTrace(sampledAt: at(20), enqueuedAt: at(21),
                                            startedAt: at(25), finishedAt: at(27), returned: true)
        let expectedActivity: String = "sample=20.000 enqueue=21.000 start=25.000 return=27.000 queueMs=4000 activityMs=2000 sampleAgeMs=7000 result=returned"
        check(activity.formatted == expectedActivity, "Activity timing stages changed")
        check(activity.queueMilliseconds == 4_000 && activity.activityMilliseconds == 2_000,
              "Immediate anomaly detection lost the original durations")
        let timeout = ActivityTimingTrace(sampledAt: nil, enqueuedAt: at(41),
                                           startedAt: at(42), finishedAt: at(43), returned: false)
        let expectedTimeout: String = "sample=nil enqueue=41.000 start=42.000 return=43.000 queueMs=1000 activityMs=1000 sampleAgeMs=nil result=timeout"
        check(timeout.formatted == expectedTimeout, "Timeout or missing sample data changed")
        print("PASS: deferred sample/activity formatting preserves fields, precision and missing values")

        var electrical = ElectricalEvidenceTrace(date: at(50.125), isCharging: true,
                                                  inputWatts: 15.2, batteryWatts: -4.4,
                                                  shownWatts: 3.14, shownIsBatterySide: false,
                                                  thermalState: 2)
        electrical.capture(name: "Charger VQ0u", index: 7, value: 14.5)
        electrical.capture(name: "Charger IQ0u", index: 8, value: -1.052)
        electrical.capture(name: "Charger VQ0u", index: 3, value: 14.55)
        electrical.capture(name: "Charger QQ0u", index: 9, value: 0.726)
        electrical.capture(name: "Charger WQ0u", index: 10, value: 0.125)
        electrical.capture(name: "gas gauge battery", index: 18, value: 38.7)
        electrical.capture(name: "gas gauge battery", index: 16, value: 45.9)
        electrical.capture(name: "Gas Gauge Battery", index: 999, value: 99)
        electrical.capture(name: "PMU tcal", index: 998, value: 51.8)
        let expectedElectrical: String = "t=50.125 charge=true inputW=15.20 batteryW=-4.40 shown=3.14 shownSide=input VQ0u=[7:14.500,3:14.550] IQ0u=[8:-1.052] QQ0u=[9:0.726] WQ0u=[10:0.125] gaugeC=[18:38.700,16:45.900] thermal=2"
        check(electrical.formatted == expectedElectrical,
              "Single-pass capture changed duplicate order, signs, exact names or output")
        check(electrical.voltage.count == 2 && electrical.batteryGauge.count == 2,
              "Duplicate sensor evidence was lost")
        let noRails = ElectricalEvidenceTrace(date: at(0), isCharging: false,
                                               inputWatts: nil, batteryWatts: nil,
                                               shownWatts: nil, shownIsBatterySide: true,
                                               thermalState: 0)
        let expectedNoRails: String = "t=0.000 charge=false inputW=— batteryW=— shown=— shownSide=battery VQ0u=[—] IQ0u=[—] QQ0u=[—] WQ0u=[—] gaugeC=[—] thermal=0"
        check(noRails.formatted == expectedNoRails, "Missing electrical values changed")
        print("PASS: one-pass electrical capture preserves duplicate indices, signs and unknown rails")

        var history: [SampleTimingTrace] = []
        for tick in 1...65 {
            let entry = SampleTimingTrace(tick: tick, startedAt: at(Double(tick)),
                                           cpuSampledAt: at(Double(tick)), cpuIntervalSeconds: 1,
                                           finishedAt: at(Double(tick)), publishedAt: at(Double(tick)),
                                           elapsedMilliseconds: 0, cpuUsagePercent: nil)
            MonitoringTrace.append(entry, to: &history, limit: 60)
        }
        check(history.count == 60 && history.first?.tick == 6 && history.last?.tick == 65,
              "Trace capacity or oldest-first eviction changed")
        let exported: [Int] = history.suffix(45).map { $0.tick }
        check(exported == Array(21...65), "Report suffix order or 45-row selection changed")
        print("PASS: newest 60 records retained in order, report selects the latest 45")

        let unavailable = BatteryLevelCandidates(mobileGestaltPercent: nil,
                                                  powerSourcePercent: nil, uiDevicePercent: nil)
        check(unavailable.formatted == "MobileGestalt — · powerd — · UIDevice —",
              "Unavailable battery candidate wording changed")
        let candidates = BatteryLevelCandidates(mobileGestaltPercent: 70,
                                                 powerSourcePercent: 75, uiDevicePercent: 75)
        check(candidates.formatted == "MobileGestalt 70 · powerd 75 · UIDevice 75",
              "Battery candidate ordering changed")
        check(candidates == BatteryLevelCandidates(mobileGestaltPercent: 70,
                                                    powerSourcePercent: 75, uiDevicePercent: 75),
              "An unchanged candidate tuple cannot reuse its formatted text")
        check(candidates != BatteryLevelCandidates(mobileGestaltPercent: 70,
                                                    powerSourcePercent: nil, uiDevicePercent: 75),
              "A newly missing candidate did not invalidate formatted text")
        print("PASS: battery candidate equality compares all three actual optional values")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = ProblemReportRecorder(directory: directory)
        recorder.record("before", "ordered-before-electrical")
        recorder.recordElectrical(electrical)
        electrical.capture(name: "Charger VQ0u", index: 999, value: 9.999)
        recorder.record("after", "ordered-after-electrical")
        let report = try await recorder.export(summary: "trace test", note: "")
        let text = try String(contentsOf: report.url, encoding: .utf8)
        check(text.contains("[electrical] " + expectedElectrical),
              "Deferred checkpoint failed to persist the original trace")
        check(!text.contains("999:9.999"), "Later producer mutation changed the queued checkpoint")
        let before = text.range(of: "ordered-before-electrical")!.lowerBound
        let checkpoint = text.range(of: "[electrical] " + expectedElectrical)!.lowerBound
        let after = text.range(of: "ordered-after-electrical")!.lowerBound
        check(before < checkpoint && checkpoint < after,
              "Deferred serialization reordered writes or export overtook it")
        print("PASS: utility-queue checkpoint preserves captured values and event/export ordering")
    }
}
