import Foundation

@main struct ForecastTests {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }
    static func date(_ second: Double) -> Date { Date(timeIntervalSince1970: second) }
    static func near(_ value: Double?, _ expected: Double, _ message: String) {
        check(value.map { abs($0 - expected) < 0.0001 } ?? false, message)
    }
    static func main() {
        var tracker = ChargeForecastTracker()
        for second in stride(from: 0, through: 120, by: 15) {
            let level = second >= 120 ? 52 : second >= 60 ? 51 : 50
            tracker.observe(date: date(Double(second)), percent: level, connected: true, charging: true)
            if second < 120 { check(tracker.result == nil, "First observation must not count as a transition") }
        }
        guard let forecast = tracker.result else { preconditionFailure("Two changes should create a forecast") }
        check(forecast.measuredRise == 1 && forecast.step == 1, "Observed rise or step is incorrect")
        near(forecast.secondsRemaining(to: 80, from: 52, at: date(120)), 1680, "Wrong estimate to 80%")
        near(forecast.secondsRemaining(to: 100, from: 52, at: date(120)), 5130, "Taper weights changed")
        near(forecast.secondsRemaining(to: 80, from: 52, at: date(150)), 1650, "Elapsed time was not deducted")
        near(forecast.secondsRemaining(to: 80, from: 52, at: date(10_000)), 1620,
             "A late level transition must not count the whole charge to zero")
        near(forecast.secondsRemaining(to: 80, from: 81, at: date(120)), 0, "Reached target must return zero")
        check(forecast.secondsRemaining(to: 101, from: 52, at: date(120)) == nil,
              "Invalid target was accepted")

        tracker.observe(date: date(121), percent: 52, connected: false, charging: false)
        check(tracker.result == nil, "Unplug must clear the forecast")
        tracker.observe(date: date(122), percent: 52, connected: nil, charging: true)
        check(tracker.result == nil, "Unknown connection must not invent a forecast")
        for second in stride(from: 0, through: 120, by: 15) {
            let level = second >= 120 ? 60 : second >= 60 ? 55 : 50
            tracker.observe(date: date(200 + Double(second)), percent: level, connected: true, charging: true)
        }
        guard let stepped = tracker.result else { preconditionFailure("Five-percent steps should be usable") }
        check(stepped.step == 5, "Five-percent level granularity was lost")
        near(stepped.secondsRemaining(to: 80, from: 60, at: date(320)), 240, "Step-aware forecast is wrong")
        tracker.observe(date: date(351), percent: 61, connected: true, charging: true)
        check(tracker.result == nil, "A sampling gap must discard the old rate")
        tracker.observe(date: date(352), percent: 60, connected: true, charging: true)
        check(tracker.result == nil, "A falling level must discard the old rate")
        tracker.observe(date: date(353), percent: 60, connected: true, charging: false)
        check(tracker.result == nil, "Charging on hold must not keep a countdown")
        check(ChargeForecast(levelChanges: [(date(1), 51), (date(0), 52)]) == nil,
              "Backward transition timestamps were accepted")
        check(ChargeForecast(levelChanges: [(date(0), 51), (date(1), 51)]) == nil,
              "Unchanged levels were treated as a rise")
        print("PASS: observed charge forecast, taper, coarse levels and interrupted sampling")
    }
}
