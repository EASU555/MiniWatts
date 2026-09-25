import Darwin
import Foundation

/// Whole-device traffic on the active Wi-Fi and cellular interfaces. This is
/// device traffic, not a per-app accounting API. Interface counters are 32-bit,
/// so calculate each interface's delta before adding them together.
nonisolated struct NetworkTrafficReader {
    nonisolated struct Counters: Sendable {
        let received: UInt32
        let sent: UInt32
    }

    nonisolated struct Sample: Sendable {
        let downloadBytesPerSecond: Double?
        let uploadBytesPerSecond: Double?
        let sampledAt: Date
        let intervalSeconds: TimeInterval?
        let interfaceNames: [String]
    }

    private var previous: (counters: [String: Counters], uptime: TimeInterval)?

    mutating func read() -> Sample {
        let sampledAt = Date.now
        let uptime = ProcessInfo.processInfo.systemUptime
        guard let counters = Self.interfaceCounters() else {
            previous = nil
            return Sample(downloadBytesPerSecond: nil, uploadBytesPerSecond: nil,
                          sampledAt: sampledAt, intervalSeconds: nil, interfaceNames: [])
        }
        return update(counters: counters, uptime: uptime, sampledAt: sampledAt)
    }

    /// Also used by deterministic tests for counter rollover, resets, and path changes.
    mutating func update(counters: [String: Counters],
                         uptime: TimeInterval,
                         sampledAt: Date) -> Sample {
        let names = counters.keys.sorted()
        defer { previous = counters.isEmpty ? nil : (counters, uptime) }
        guard !counters.isEmpty, let previous else {
            return Sample(downloadBytesPerSecond: nil, uploadBytesPerSecond: nil,
                          sampledAt: sampledAt, intervalSeconds: nil, interfaceNames: names)
        }
        let interval = uptime - previous.uptime
        // A resume after suspension must not report the whole background gap as
        // a current speed. Wait for the next adjacent sample instead.
        guard interval > 0, interval <= 5 else {
            return Sample(downloadBytesPerSecond: nil, uploadBytesPerSecond: nil,
                          sampledAt: sampledAt, intervalSeconds: interval, interfaceNames: names)
        }

        var received: UInt64 = 0
        var sent: UInt64 = 0
        var matched = false
        for (name, current) in counters {
            guard let old = previous.counters[name],
                  let incoming = Self.delta(current.received, since: old.received),
                  let outgoing = Self.delta(current.sent, since: old.sent) else { continue }
            matched = true
            received += UInt64(incoming)
            sent += UInt64(outgoing)
        }
        guard matched else {
            return Sample(downloadBytesPerSecond: nil, uploadBytesPerSecond: nil,
                          sampledAt: sampledAt, intervalSeconds: interval, interfaceNames: names)
        }
        return Sample(downloadBytesPerSecond: Double(received) / interval,
                      uploadBytesPerSecond: Double(sent) / interval,
                      sampledAt: sampledAt, intervalSeconds: interval,
                      interfaceNames: names)
    }

    private static func delta(_ current: UInt32, since old: UInt32) -> UInt32? {
        if current >= old { return current - old }
        // A true 32-bit rollover crosses the ends of the range. A drop at any
        // other point is more likely an interface counter reset; discard it.
        guard old >= 0xF000_0000, current <= 0x0FFF_FFFF else { return nil }
        return current &- old
    }

    private static func interfaceCounters() -> [String: Counters]? {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return nil }
        defer { freeifaddrs(first) }

        var result: [String: Counters] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            let item = entry.pointee
            cursor = item.ifa_next
            guard let address = item.ifa_addr,
                  Int32(address.pointee.sa_family) == AF_LINK,
                  item.ifa_flags & UInt32(IFF_UP) != 0,
                  let data = item.ifa_data else { continue }
            let name = String(cString: item.ifa_name)
            // Exclude loopback, AWDL, tunnels/VPN and other virtual interfaces:
            // counting those as well as their physical path doubles traffic.
            guard name.hasPrefix("en") || name.hasPrefix("pdp_ip") else { continue }
            let stats = data.assumingMemoryBound(to: if_data.self).pointee
            result[name] = Counters(received: UInt32(truncatingIfNeeded: stats.ifi_ibytes),
                                    sent: UInt32(truncatingIfNeeded: stats.ifi_obytes))
        }
        return result
    }
}
