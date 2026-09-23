import QuartzCore
import UIKit

/// A short-lived run-loop cadence probe for the dashboard. It starts only while
/// the user scrolls, and its report is explicitly *not* a rendered-FPS claim:
/// Core Animation and the display can still choose a different presentation rate.
@MainActor final class DashboardScrollProbe: NSObject {
    private var link: CADisplayLink?
    private var previousTimestamp: CFTimeInterval?
    private var intervals: [Double] = []
    private var startedAt: CFTimeInterval = 0

    func start() {
        guard link == nil else { return }
        intervals.removeAll(keepingCapacity: true)
        previousTimestamp = nil
        startedAt = CACurrentMediaTime()
        let newLink = CADisplayLink(target: self, selector: #selector(step(_:)))
        // The default follows the screen's maximum supported rate. Do not force
        // 120 Hz: Low Power Mode, thermal policy and iOS may legitimately lower it.
        newLink.add(to: .main, forMode: .common)
        link = newLink
    }

    func stop() {
        guard let link else { return }
        link.invalidate()
        self.link = nil
        let duration = CACurrentMediaTime() - startedAt
        guard duration >= 0.5, intervals.count >= 10 else { return }
        let ordered = intervals.sorted()
        let median = ordered[ordered.count / 2]
        let p95 = ordered[min(Int(Double(ordered.count) * 0.95), ordered.count - 1)]
        let over16 = intervals.filter { $0 > 1.0 / 60.0 }.count
        let maximum = UIScreen.main.maximumFramesPerSecond
        let summary = String(
            format: "Dashboard scroll CADisplayLink callbacks (not rendered FPS): duration=%.2fs callbacks=%d median=%.1fms p95=%.1fms over16.7ms=%d maxScreenHz=%d lowPower=%@ thermal=%ld",
            duration, intervals.count, median * 1_000, p95 * 1_000,
            over16, maximum,
            ProcessInfo.processInfo.isLowPowerModeEnabled ? "yes" : "no",
            ProcessInfo.processInfo.thermalState.rawValue
        )
        ProblemReportRecorder.shared.record("scroll", summary)
    }

    @objc private func step(_ link: CADisplayLink) {
        if let previousTimestamp {
            let interval = link.timestamp - previousTimestamp
            if interval > 0 { intervals.append(interval) }
        }
        previousTimestamp = link.timestamp
    }
}
