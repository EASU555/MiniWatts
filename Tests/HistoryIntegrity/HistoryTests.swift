import Foundation

// These standalone tests compile the real records and energy model, without the
// private sensor engine or any UI framework.
nonisolated struct PowerSnapshot {
    let date: Date
    let inputWatts: Double?
    let batteryWatts: Double?
    let batteryCurrent: Double?
}

nonisolated struct ChargeReading: Codable, Hashable {
    let percent: Int?
}

@main struct HistoryTests {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }

    static func charge(percent: Int? = nil) -> ChargeSession {
        ChargeSession(start: Date(timeIntervalSince1970: 0), startPercent: percent,
                      adapterName: nil, adapterRatedWatts: nil, isWireless: false)
    }

    static func sample(_ offset: TimeInterval, percent: Int?, temperature: Double? = nil,
                       startsNewSegment: Bool? = nil) -> ChargeSample {
        ChargeSample(offset: offset, inputWatts: 0, batteryWatts: nil,
                     percent: percent, batteryTemperature: temperature,
                     hottestTemperature: nil, throttled: false,
                     startsNewSegment: startsNewSegment)
    }

    static func near(_ value: Double?, _ expected: Double, _ message: String) {
        check(value.map { abs($0 - expected) < 0.000001 } ?? false, message)
    }

    static func main() throws {
        var unknown = charge()
        check(unknown.gainedPercent == nil, "Missing percentage became zero gain")
        unknown.recordPercent(nil)
        check(unknown.startPercent == nil && unknown.endPercent == nil,
              "An unavailable first percentage became a measured zero")
        unknown.recordPercent(68)
        check(unknown.startPercent == 68 && unknown.endPercent == 68,
              "First valid percentage did not establish the baseline")
        check(unknown.gainedPercent == 0, "First available percentage invented a gain")
        unknown.recordPercent(69)
        check(unknown.gainedPercent == 1, "Observed gain should start at the first valid percentage")
        unknown.recordPercent(nil)
        check(unknown.startPercent == 68 && unknown.endPercent == nil && unknown.gainedPercent == nil,
              "A missing current percentage reused a previous level")
        unknown.recordPercent(70)
        check(unknown.gainedPercent == 2, "A temporary missing reading reset the baseline")
        unknown.recordPercent(101)
        check(unknown.endPercent == nil, "An invalid percentage became a valid observation")

        var zero = charge(percent: 0)
        zero.recordPercent(1)
        check(zero.startPercent == 0 && zero.gainedPercent == 1,
              "A real zero percentage was treated as unavailable")
        let roundTrip = try JSONDecoder().decode(ChargeSession.self, from: JSONEncoder().encode(unknown))
        check(roundTrip.startPercent == 68 && roundTrip.endPercent == nil,
              "Percentage availability did not survive persistence")
        print("PASS: missing percentages, first valid baseline, real zero and round trip")

        // All nonoptional fields from the preceding ChargeSession/ChargeSample
        // schema are present. Old integer percentages and real zero must decode.
        let legacyJSON = #"""
        {"id":"00000000-0000-0000-0000-000000000001","start":0,"end":10,
         "startPercent":0,"endPercent":1,"totals":{"integratedSeconds":10},
         "samples":[{"offset":0,"inputWatts":0,"batteryWatts":0,"percent":0,
                     "batteryTemperature":30,"hottestTemperature":35,"throttled":false}],
         "peakInputWatts":0,"peakBatteryWatts":0,"isWireless":false,"throttledSeconds":0}
        """#
        let legacy = try JSONDecoder().decode(ChargeSession.self, from: Data(legacyJSON.utf8))
        check(legacy.startPercent == 0 && legacy.endPercent == 1 && legacy.gainedPercent == 1,
              "Legacy integer percentages were lost")
        check(legacy.samples[0].percent == 0 && legacy.samples[0].startsNewSegment == nil,
              "A legacy sample lost zero or invented a continuity marker")
        let missingJSON = legacyJSON
            .replacingOccurrences(of: "\"startPercent\":0,", with: "")
            .replacingOccurrences(of: "\"endPercent\":1,", with: "")
            .replacingOccurrences(of: "\"percent\":0,", with: "")
        let missing = try JSONDecoder().decode(ChargeSession.self, from: Data(missingJSON.utf8))
        check(missing.startPercent == nil && missing.endPercent == nil && missing.samples[0].percent == nil,
              "Absent JSON percentages became fabricated readings")
        let marked = sample(5, percent: nil, startsNewSegment: true)
        let restoredMarker = try JSONDecoder().decode(ChargeSample.self, from: JSONEncoder().encode(marked))
        check(restoredMarker.percent == nil && restoredMarker.startsNewSegment == true,
              "Missing percentage or explicit continuity did not persist")
        print("PASS: old JSON integers, absent optional fields and continuity migration")

        let empty = HistorySummary(sessions: [])
        check(empty.measuredInputWattHours == nil && empty.measuredBatteryWattHours == nil,
              "Empty history reported measured zero")
        var wireless = charge()
        wireless.isWireless = true
        wireless.totals.batteryWattHours = 2
        wireless.totals.batteryIntegratedSeconds = 10
        let wirelessSummary = HistorySummary(sessions: [wireless])
        check(wirelessSummary.measuredInputWattHours == nil, "Wireless history claimed zero delivered energy")
        near(wirelessSummary.measuredBatteryWattHours, 2, "Wireless battery energy was lost")

        var measuredZero = charge()
        measuredZero.totals.inputIntegratedSeconds = 10
        measuredZero.totals.batteryIntegratedSeconds = 10
        let zeroSummary = HistorySummary(sessions: [measuredZero])
        check(zeroSummary.measuredInputWattHours == 0 && zeroSummary.measuredBatteryWattHours == 0,
              "Measured zero became unavailable")
        var unobserved = charge()
        unobserved.totals.inputWattHours = 99
        unobserved.totals.batteryWattHours = 99
        let mixed = HistorySummary(sessions: [wireless, measuredZero, unobserved])
        near(mixed.measuredInputWattHours, 0, "Unobserved raw input total polluted history")
        near(mixed.measuredBatteryWattHours, 2, "Unobserved raw battery total polluted history")

        var small = charge()
        small.totals.pairedInputWattHours = 1
        small.totals.pairedBatteryWattHours = 0.5
        small.totals.pairedIntegratedSeconds = 10
        var large = charge()
        large.totals.pairedInputWattHours = 9
        large.totals.pairedBatteryWattHours = 8.1
        large.totals.pairedIntegratedSeconds = 10
        let paired = HistorySummary(sessions: [small, large, legacy, wireless])
        near(paired.inputToCellPercent, 86, "History share must be weighted by paired input energy")
        check(wirelessSummary.inputToCellPercent == nil && empty.inputToCellPercent == nil,
              "Unpaired history invented an efficiency")
        print("PASS: optional channel totals, observed zero and paired weighted summary")

        let separated = [sample(0, percent: 0, temperature: 30),
                         sample(5, percent: nil), sample(10, percent: 1, temperature: 31)]
        let percentages = SessionChartSeries.points(separated, prefix: "percent") { $0.percent.map(Double.init) }
        check(percentages.map(\.value) == [0, 1], "Chart lost a real zero or plotted a missing reading")
        check(percentages[0].series != percentages[1].series, "Chart connected across unavailable percentages")
        check(SessionChartSeries.singletonPoints(in: percentages).count == 2,
              "Isolated observations would disappear as invisible one-point lines")
        let temperatures = SessionChartSeries.points(separated, prefix: "temperature") { $0.batteryTemperature }
        check(temperatures[0].series != temperatures[1].series, "Chart connected across unavailable temperatures")

        let discontinuous = [sample(0, percent: 50), sample(5, percent: 51),
                             sample(10, percent: 52, startsNewSegment: true)]
        let broken = SessionChartSeries.points(discontinuous, prefix: "percent") { $0.percent.map(Double.init) }
        check(broken[0].series == broken[1].series && broken[1].series != broken[2].series,
              "Explicit sampling break failed to start a new segment")
        check(SessionChartSeries.singletonPoints(in: broken).map(\.offset) == [10],
              "Only a single-observation segment needs a point mark")
        let thinned = SessionChartSeries.points([sample(0, percent: 50), sample(30, percent: 51)],
                                               prefix: "percent") { $0.percent.map(Double.init) }
        check(thinned[0].series == thinned[1].series,
              "Chart invented an unknown interval from intentionally thinned sample spacing")
        let sparklineSamples = (0..<100).map { index in
            ChargeSample(offset: Double(index),
                         inputWatts: index == 20 ? nil : (index == 25 ? 200 : Double(index)),
                         batteryWatts: nil, percent: nil, batteryTemperature: nil,
                         hottestTemperature: nil, throttled: false,
                         startsNewSegment: index == 33 ? true : nil)
        }
        let sparkline = SessionChartSeries.sparklinePoints(sparklineSamples, resolution: 1)
        check(sparkline.count == 3 && Set(sparkline.map(\.series)).count == 3,
              "Sparkline downsampling erased a missing reading or explicit break inside one bucket")
        check(sparkline.map(\.value).max() == 200, "Sparkline downsampling erased a power peak")
        let isolatedSparkline = SessionChartSeries.sparklinePoints([sample(0, percent: nil)])
        check(SessionChartSeries.singletonPoints(in: isolatedSparkline).count == 1,
              "A session with one valid power sample would have an empty sparkline")
        print("PASS: chart gaps, continuity, singleton visibility, thinning and sparkline peaks")

        let widgetJSON = #"""
        {"reading":{"percent":72},"lastSession":{"start":0,"end":10,
         "startPercent":0,"endPercent":1,"storedWattHours":0,
         "deliveredWattHours":0,"peakWatts":0,"isWireless":false}}
        """#
        let widget = try JSONDecoder().decode(WidgetSnapshot.self, from: Data(widgetJSON.utf8))
        check(widget.lastSession?.gainedPercent == 1 && widget.lastSession?.storedWattHours == 0,
              "Legacy widget lost real zero and old integer percentages")
        let missingWidgetJSON = widgetJSON
            .replacingOccurrences(of: "\"startPercent\":0,", with: "")
            .replacingOccurrences(of: "\"endPercent\":1,", with: "")
            .replacingOccurrences(of: "\"storedWattHours\":0,", with: "")
        let missingWidget = try JSONDecoder().decode(WidgetSnapshot.self, from: Data(missingWidgetJSON.utf8))
        check(missingWidget.lastSession?.gainedPercent == nil && missingWidget.lastSession?.storedWattHours == nil,
              "Widget fabricated missing historical percentage or energy")
        let restoredWidget = try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(missingWidget))
        check(restoredWidget.lastSession?.startPercent == nil && restoredWidget.lastSession?.storedWattHours == nil,
              "Widget optional data did not survive round trip")
        print("PASS: widget migration, missing values and measured zero")
    }
}
