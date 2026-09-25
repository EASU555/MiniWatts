import Foundation

@main struct TrafficTests {
    typealias Counters = NetworkTrafficReader.Counters

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }

    static func at(_ second: TimeInterval) -> Date {
        Date(timeIntervalSince1970: second)
    }

    static func main() {
        var reader = NetworkTrafficReader()
        let first = reader.update(counters: ["en0": Counters(received: 1_000, sent: 2_000)],
                                  uptime: 10, sampledAt: at(10))
        check(first.downloadBytesPerSecond == nil, "First counter read is not a speed")

        let active = reader.update(counters: ["en0": Counters(received: 3_000, sent: 2_500)],
                                   uptime: 11, sampledAt: at(11))
        check(active.downloadBytesPerSecond == 2_000, "Download delta wrong")
        check(active.uploadBytesPerSecond == 500, "Upload delta wrong")

        let idle = reader.update(counters: ["en0": Counters(received: 3_000, sent: 2_500)],
                                 uptime: 12, sampledAt: at(12))
        check(idle.downloadBytesPerSecond == 0, "Idle traffic must show zero")

        let delayed = reader.update(counters: ["en0": Counters(received: 8_000, sent: 3_000)],
                                    uptime: 30, sampledAt: at(30))
        check(delayed.downloadBytesPerSecond == nil, "Background gap is not a live speed")
        let resumed = reader.update(counters: ["en0": Counters(received: 8_500, sent: 3_200)],
                                    uptime: 31, sampledAt: at(31))
        check(resumed.downloadBytesPerSecond == 500, "Adjacent post-resume sample was lost")

        let switched = reader.update(counters: ["pdp_ip0": Counters(received: 10, sent: 20)],
                                     uptime: 32, sampledAt: at(32))
        check(switched.downloadBytesPerSecond == nil, "Path switch invented traffic")
        let cellular = reader.update(counters: ["pdp_ip0": Counters(received: 110, sent: 220)],
                                     uptime: 33, sampledAt: at(33))
        check(cellular.downloadBytesPerSecond == 100, "Cellular delta wrong")

        var multiple = NetworkTrafficReader()
        _ = multiple.update(counters: ["en0": Counters(received: 10, sent: 20),
                                       "pdp_ip0": Counters(received: 100, sent: 200)],
                            uptime: 1, sampledAt: at(1))
        let combined = multiple.update(counters: ["en0": Counters(received: 110, sent: 70),
                                                  "pdp_ip0": Counters(received: 400, sent: 350)],
                                       uptime: 2, sampledAt: at(2))
        check(combined.downloadBytesPerSecond == 400, "Active interfaces were not combined")
        check(combined.uploadBytesPerSecond == 200, "Upload interfaces were not combined")

        var rollover = NetworkTrafficReader()
        _ = rollover.update(counters: ["en0": Counters(received: .max - 5, sent: .max - 10)],
                            uptime: 1, sampledAt: at(1))
        let wrapped = rollover.update(counters: ["en0": Counters(received: 4, sent: 9)],
                                      uptime: 2, sampledAt: at(2))
        check(wrapped.downloadBytesPerSecond == 10, "32-bit receive rollover wrong")
        check(wrapped.uploadBytesPerSecond == 20, "32-bit send rollover wrong")

        var reset = NetworkTrafficReader()
        _ = reset.update(counters: ["en0": Counters(received: 20_000, sent: 10_000)],
                         uptime: 1, sampledAt: at(1))
        let restarted = reset.update(counters: ["en0": Counters(received: 100, sent: 50)],
                                       uptime: 2, sampledAt: at(2))
        check(restarted.downloadBytesPerSecond == nil, "Counter reset became a huge speed")
        let next = reset.update(counters: ["en0": Counters(received: 300, sent: 100)],
                                uptime: 3, sampledAt: at(3))
        check(next.downloadBytesPerSecond == 200, "Counter reset did not recover")

        print("PASS: network traffic baseline, idle, gap, path switch, aggregation, rollover, reset")
    }
}
