import Foundation

@main struct PerformancePolicyTests {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }

    static func legacyPower(_ values: [(Double?, Double?)], headroom: Double) -> Double {
        let readings: [Double] = values.flatMap { [$0.0, $0.1] }.compactMap { $0 }
        return max((readings.filter(\.isFinite).max() ?? 0) * headroom, 5)
    }

    static func main() {
        let fixtures: [[(Double?, Double?)]] = [
            [], [(nil, nil)], [(0, 0)], [(-10, -4)],
            [(45, 21), (14, nil), (nil, 26)],
            [(.nan, .infinity), (-.infinity, nil), (0, 3)],
            [(nil, 0), (nil, nil), (32, 18)]
        ]
        for readings in fixtures {
            for headroom in [1.2, 1.25] {
                let actual = ChartDomain.powerCeiling(readings, headroom: headroom) { $0 }
                check(actual == legacyPower(readings, headroom: headroom),
                      "Streaming power ceiling changed finite/nil/zero/negative semantics")
            }
        }
        var scans = 0
        let many: [(Double?, Double?)] = (0..<1_500).map { index in
            (Double(index % 51), Double(index % 29))
        }
        let ceiling = ChartDomain.powerCeiling(many, headroom: 1.2) { reading in
            scans += 1
            return reading
        }
        check(scans == many.count && ceiling == 60,
              "A history domain should read each sample exactly once")
        print("PASS: power domain parity and one-pass reduction across 1,500 samples")

        let noValues: [Double] = []
        check(ChartDomain.temperature(noValues, paddingFraction: 0.2,
                                      minimumPadding: 1, fallback: 20...45) == 20...45,
              "Empty temperature chart lost its fallback")
        check(ChartDomain.temperature([Double.nan, .infinity, -.infinity],
                                      paddingFraction: 0.3, minimumPadding: 1.5,
                                      fallback: 20...50) == 20...50,
              "Nonfinite temperatures should not form an axis")
        check(ChartDomain.temperature([33, 33], paddingFraction: 0.2,
                                      minimumPadding: 1, fallback: 20...45) == 32...34,
              "Flat temperature series lost minimum padding")
        check(ChartDomain.temperature([0, 10, 20].lazy, paddingFraction: 0.2,
                                      minimumPadding: 1, fallback: 20...45) == -4...24,
              "Temperature padding changed")
        print("PASS: temperature domain empty/flat/missing and padding semantics")

        check(ChargeStatusReadPolicy.shouldRetry(after: 0), "Success must keep live reads")
        check(!ChargeStatusReadPolicy.shouldRetry(after: ChargeStatusReadPolicy.notPrivileged),
              "Sandbox-denied requests must not repeat each tick")
        let transientResults: [Int32] = [-1, 1, Int32(bitPattern: 0xe00002bd)]
        for transient in transientResults {
            check(ChargeStatusReadPolicy.shouldRetry(after: transient),
                  "Transient errors must remain retryable")
        }
        print("PASS: only explicit not-privileged status disables repeated requests")
    }
}
