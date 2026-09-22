import Darwin
import Foundation

/// Whole-device CPU busy time over the interval between two host samples.
/// This is not the CPU use of MiniWatts, a processor frequency, or a power reading.
nonisolated struct SystemCPULoadReader {
    private struct Ticks {
        let user: UInt32
        let system: UInt32
        let idle: UInt32
        let nice: UInt32

        init(_ info: host_cpu_load_info_data_t) {
            user = info.cpu_ticks.0
            system = info.cpu_ticks.1
            idle = info.cpu_ticks.2
            nice = info.cpu_ticks.3
        }
    }

    private var previous: (ticks: Ticks, date: Date)?

    mutating func read() -> Double? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size
                                           / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            previous = nil
            return nil
        }

        let now = Date.now
        let current = Ticks(info)
        defer { previous = (current, now) }
        guard let previous,
              now.timeIntervalSince(previous.date) <= 5 else { return nil }

        // The kernel counters are UInt32 and eventually wrap. Wrapping subtraction
        // still yields the correct short-interval delta without trapping.
        let busy = UInt64(current.user &- previous.ticks.user)
            + UInt64(current.system &- previous.ticks.system)
            + UInt64(current.nice &- previous.ticks.nice)
        let idle = UInt64(current.idle &- previous.ticks.idle)
        let total = busy + idle
        guard total > 0 else { return nil }
        return Double(busy) / Double(total) * 100
    }
}
