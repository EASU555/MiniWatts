import Foundation

@main
struct PolicyTests {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    static func main() {
        let gauges = BatteryGaugeSummary(values: [38.7, 38.7, 38.7, 45.9])!
        check(gauges.count == 4, "Repeated gas-gauge sensors were collapsed")
        check(abs(gauges.minimum - 38.7) < 0.01, "Wrong minimum")
        check(abs(gauges.median - 38.7) < 0.01, "A hot sensor shifted the median")
        check(abs(gauges.maximum - 45.9) < 0.01, "Highest reading was hidden")
        check(abs(gauges.spread - 7.2) < 0.01, "Wrong spread")
        check(BatteryGaugeSummary(values: [38.7]) == nil, "One sensor is not a distribution")
        check(BatteryGaugeSummary(values: [.nan, 31.0, 32.0])?.count == 2,
              "Invalid sensor values entered the summary")
        print("PASS: battery gauge evidence preserves the 38.7/45.9 °C split")

        check(!BackgroundSamplingPolicy.keepsSampling(pipActive: false, pipStarting: false,
                                                      pipStopping: false),
              "Live Activity alone must not claim background sampling")
        check(BackgroundSamplingPolicy.keepsSampling(pipActive: true, pipStarting: false,
                                                     pipStopping: false),
              "Active PiP lost background sampling")
        check(BackgroundSamplingPolicy.keepsSampling(pipActive: false, pipStarting: true,
                                                     pipStopping: false),
              "PiP start transition lost background sampling")
        check(BackgroundSamplingPolicy.keepsSampling(pipActive: false, pipStarting: false,
                                                     pipStopping: true),
              "PiP stop transition lost background sampling")
        print("PASS: PiP active and both transitions preserve the sampling contract")
    }
}
