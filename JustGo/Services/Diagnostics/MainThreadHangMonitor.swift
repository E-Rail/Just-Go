#if DEBUG
import Foundation
import os

/// DEBUG-only main-thread responsiveness probe. A main-runloop timer stamps a heartbeat; a
/// background thread watches how stale that stamp gets. Staleness == the main thread is not
/// servicing its runloop == the UI is frozen, which is exactly what we need to measure (and
/// what wall-clock timing around individual functions cannot tell us on its own).
enum MainThreadHangMonitor {
    private static let log = Logger(subsystem: "com.e-rail.just-go.diag", category: "hang")
    nonisolated(unsafe) private static var lastBeat = CFAbsoluteTimeGetCurrent()
    private static let lock = NSLock()

    static func start() {
        let timer = Timer(timeInterval: 0.02, repeats: true) { _ in
            lock.lock()
            lastBeat = CFAbsoluteTimeGetCurrent()
            lock.unlock()
        }
        RunLoop.main.add(timer, forMode: .common)

        Thread.detachNewThread {
            Thread.current.name = "just-go-hang-monitor"
            var worstStale: Double = 0
            while true {
                Thread.sleep(forTimeInterval: 0.02)
                lock.lock()
                let beat = lastBeat
                lock.unlock()
                let stale = CFAbsoluteTimeGetCurrent() - beat
                if stale > 0.2 {
                    worstStale = max(worstStale, stale)
                } else if worstStale > 0 {
                    log.error("JUSTGOHANG \(Int(worstStale * 1000))ms")
                    worstStale = 0
                }
            }
        }
    }

    /// Logs how long a synchronous main-thread block took, so a measured hang can be
    /// attributed to a specific stage instead of inferred.
    @discardableResult
    static func measure<T>(_ label: String, _ work: () throws -> T) rethrows -> T {
        let start = CFAbsoluteTimeGetCurrent()
        defer {
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
            if elapsed > 8 {
                log.error("JUSTGOSTAGE \(label, privacy: .public) \(Int(elapsed))ms")
            }
        }
        return try work()
    }
}
#endif
