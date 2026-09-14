#if DEBUG
import Foundation
import os

/// DEBUG-only main-thread responsiveness probe: a main-runloop timer stamps a heartbeat and a
/// background thread logs how stale it gets. A stale heartbeat means the UI was frozen, which
/// timing individual functions cannot show.
enum MainThreadHangMonitor {
    private static let log = Logger(subsystem: "com.erail.just-go.diag", category: "hang")
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
                    log.error("JUST_GO_HANG \(Int(worstStale * 1000))ms")
                    worstStale = 0
                }
            }
        }
    }
}
#endif
