#if DEBUG
import Darwin
import Foundation
import os

/// DEBUG-only launch timeline, measured from the moment the **kernel** started the process
/// rather than from the first line of Swift that runs.
///
/// That distinction is the whole point. Time spent in `dyld`, code-signature validation and
/// debugger attach happens before any app code executes, so an in-app stopwatch cannot see it
/// and will happily report a fast launch while the user stares at a blank screen. Reading the
/// process's real start time out of the kernel makes "before main" a measurable quantity, which
/// is the only way to tell "our services are slow" apart from "the app had not started yet".
enum LaunchClock {
    private static let log = Logger(subsystem: "com.justgo.diag", category: "launch")

    /// Kernel-recorded process start, via `sysctl(KERN_PROC_PID)`. Falls back to first-touch of
    /// this static — which just means pre-main time reads as zero rather than as a wrong number.
    private static let processStart: Date = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&name, u_int(name.count), &info, &size, nil, 0) == 0 else {
            return Date()
        }
        let started = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000)
    }()

    /// Logs `label` with milliseconds elapsed since the kernel started the process.
    static func mark(_ label: String) {
        let elapsed = Date().timeIntervalSince(processStart) * 1000
        log.error("JUSTGOLAUNCH \(label, privacy: .public) +\(Int(elapsed))ms")
    }
}
#endif
