import Darwin
import Foundation

// MARK: - Stubs
//
// Only what the resolver names. `TransitNameMatching`, `ChinaClock` and `ServiceHoursResolver`
// itself are the real files, compiled by test_service_hours_resolver.sh.

enum AppLocalization {
    static func localized(_ key: String) -> String { key }
    static func text(english: String, simplified: String, traditional: String) -> String { english }
}

enum RouteServiceStatus: Equatable {
    case running
    case lastTrainSoon(minutesRemaining: Int)
    case serviceEndedToday
    case notYetStarted(startsAtText: String)
    case unknown

    var label: String {
        switch self {
        case .running: return "running"
        case .lastTrainSoon(let m): return "lastTrainSoon(\(m))"
        case .serviceEndedToday: return "serviceEnded"
        case .notYetStarted(let t): return "notYetStarted(\(t))"
        case .unknown: return "unknown"
        }
    }
}

// MARK: - Harness

final class Recorder {
    private(set) var failures = 0
    func check(_ label: String, _ actual: String, _ expected: String) {
        if actual == expected {
            print("  ok   \(label) -> \(actual)")
        } else {
            failures += 1
            print("  FAIL \(label) -> \(actual), expected \(expected)")
        }
    }
}

/// 2026-08-25 at HH:mm China Standard Time.
func at(_ hour: Int, _ minute: Int) -> Date {
    var components = DateComponents()
    components.year = 2026; components.month = 8; components.day = 25
    components.hour = hour; components.minute = minute
    return ChinaClock.calendar.date(from: components)!
}

@main
enum ServiceHoursResolverTests {
    static func main() {
        let resolver = ServiceHoursResolver()
        let recorder = Recorder()
        func check(_ l: String, _ a: String, _ e: String) { recorder.check(l, a, e) }

    // MARK: - 天通苑南, 5号线
    //
    // Live from bjsubway.com/api/guanwang/v2/getStationDetail?accLocation=150996249 on 2026-08-25:
    //   toward 宋家庄     first 5:03  last 22:51
    //   toward 天通苑北   first 6:06  last 23:57
    // Merging the two reports 5:03-23:57 in both directions, which is how a rider heading south at
    // 23:20 was told their train was running 29 minutes after it left.

    let tiantongyuannan = [
        StationServiceWindow(lineName: "5号线", direction: "宋家庄", firstTime: "5:03", lastTime: "22:51"),
        StationServiceWindow(lineName: "5号线", direction: "天通苑北", firstTime: "6:06", lastTime: "23:57")
    ]
    // 5号线 runs 天通苑北 (north) — 宋家庄 (south). Southbound from 天通苑南:
    let southbound = ["天通苑南", "立水桥北", "立水桥", "大屯路东", "惠新西街北口", "雍和宫", "宋家庄"]
    let northbound = ["天通苑南", "天通苑", "天通苑北"]

    print("天通苑南 5号线 at 23:20")
    check(
        "southbound to 宋家庄",
        resolver.verdict(
            boardingLineName: "5号线",
            onwardStationNames: southbound,
            alightingStationName: "雍和宫",
            windows: tiantongyuannan,
            at: at(23, 20)
        ).status.label,
        "serviceEnded"
    )
    check(
        "northbound to 天通苑北",
        resolver.verdict(
            boardingLineName: "5号线",
            onwardStationNames: northbound,
            alightingStationName: "天通苑",
            windows: tiantongyuannan,
            at: at(23, 20)
        ).status.label,
        "running"
    )
    // The direction that is shut must be reported as attributed, or the planner will not act on it.
    check(
        "southbound is attributed",
        String(
            resolver.verdict(
                boardingLineName: "5号线",
                onwardStationNames: southbound,
                alightingStationName: "雍和宫",
                windows: tiantongyuannan,
                at: at(23, 20)
            ).isAttributed
        ),
        "true"
    )

    // MARK: - 花园桥, 6号线 — short-turns
    //
    // Live from the same endpoint. Eastbound from 花园桥 there are two services:
    //   full run  -> 潞阳   first 5:27  last 22:45
    //   short-turn-> 草房   first 5:27  last 23:56
    // So at 23:20 the answer depends entirely on where the rider gets off, 71 minutes apart.

    let huayuanqiao = [
        StationServiceWindow(lineName: "6号线", direction: "潞阳方向", firstTime: "5:27", lastTime: "22:45"),
        StationServiceWindow(lineName: "6号线", direction: "草房方向", firstTime: "5:27", lastTime: "23:56")
    ]
    let eastbound = [
        "花园桥", "白石桥南", "车公庄", "呼家楼", "青年路", "草房",
        "物资学院路", "通州北关", "北运河西", "郝家府", "东夏园", "潞城", "潞阳"
    ]

    print("花园桥 6号线 at 23:20")
    check(
        "to 呼家楼, before the short-turn ends",
        resolver.verdict(
            boardingLineName: "6号线",
            onwardStationNames: eastbound,
            alightingStationName: "呼家楼",
            windows: huayuanqiao,
            at: at(23, 20)
        ).status.label,
        "running"
    )
    check(
        "to 潞城, beyond the short-turn",
        resolver.verdict(
            boardingLineName: "6号线",
            onwardStationNames: eastbound,
            alightingStationName: "潞城",
            windows: huayuanqiao,
            at: at(23, 20)
        ).status.label,
        "serviceEnded"
    )
    check(
        "to 草房 itself, the short-turn's own terminus",
        resolver.verdict(
            boardingLineName: "6号线",
            onwardStationNames: eastbound,
            alightingStationName: "草房",
            windows: huayuanqiao,
            at: at(23, 20)
        ).status.label,
        "running"
    )

    // MARK: - Falling back honestly
    //
    // A ring, an ambiguous branch or a station list that does not reach the alighting stop all arrive
    // here as a nil/непassing onward list. The old merged answer is still given — it is all there is —
    // but it must NOT claim to be attributed, because acting on it is how a rider gets sent to a dark
    // platform on the strength of the other direction's timetable.

    print("unattributable")
    check(
        "no onward list falls back to the merged window",
        resolver.verdict(
            boardingLineName: "5号线",
            onwardStationNames: nil,
            alightingStationName: "雍和宫",
            windows: tiantongyuannan,
            at: at(23, 20)
        ).status.label,
        "running"
    )
    check(
        "...and says it could not attribute it",
        String(
            resolver.verdict(
                boardingLineName: "5号线",
                onwardStationNames: nil,
                alightingStationName: "雍和宫",
                windows: tiantongyuannan,
                at: at(23, 20)
            ).isAttributed
        ),
        "false"
    )
    // One window is not a merge, so there is nothing to be optimistic about.
    check(
        "a lone window is attributed even with no onward list",
        String(
            resolver.verdict(
                boardingLineName: "5号线",
                onwardStationNames: nil,
                alightingStationName: "雍和宫",
                windows: [tiantongyuannan[0]],
                at: at(23, 20)
            ).isAttributed
        ),
        "true"
    )

    // MARK: - Behaviour the fix must not disturb

    print("regressions")
    check(
        "daytime is still running",
        resolver.verdict(
            boardingLineName: "5号线",
            onwardStationNames: southbound,
            alightingStationName: "雍和宫",
            windows: tiantongyuannan,
            at: at(14, 0)
        ).status.label,
        "running"
    )
    check(
        "the last-train warning still fires inside the threshold",
        resolver.verdict(
            boardingLineName: "5号线",
            onwardStationNames: southbound,
            alightingStationName: "雍和宫",
            windows: tiantongyuannan,
            at: at(22, 40)
        ).status.label,
        "lastTrainSoon(11)"
    )
    check(
        "before the first train is not the same as after the last",
        resolver.verdict(
            boardingLineName: "5号线",
            onwardStationNames: southbound,
            alightingStationName: "雍和宫",
            windows: tiantongyuannan,
            at: at(4, 30)
        ).status.label,
        "notYetStarted(5:03)"
    )
    // A service day runs past midnight, so 0:09 is *after* 23:30 rather than eighteen hours before
    // it. Both sides of midnight are checked: the wrap is the arithmetic most likely to be broken
    // by a change here, and it fails silently in the direction that strands people.
    let pastMidnight = [
        StationServiceWindow(lineName: "13号线", direction: "霍营", firstTime: "5:30", lastTime: "0:09")
    ]
    check(
        "still running before midnight",
        resolver.verdict(
            boardingLineName: "13号线",
            onwardStationNames: ["上地", "五道口", "霍营"],
            alightingStationName: "霍营",
            windows: pastMidnight,
            at: at(23, 30)
        ).status.label,
        "running"
    )
    check(
        "and still running after it",
        resolver.verdict(
            boardingLineName: "13号线",
            onwardStationNames: ["上地", "五道口", "霍营"],
            alightingStationName: "霍营",
            windows: pastMidnight,
            at: at(0, 5)
        ).status.label,
        "lastTrainSoon(4)"
    )
    check(
        "no windows at all is unknown, never running",
        resolver.verdict(
            boardingLineName: "5号线",
            onwardStationNames: southbound,
            alightingStationName: "雍和宫",
            windows: [],
            at: at(23, 20)
        ).status.label,
        "unknown"
    )

    if recorder.failures > 0 {
        print("\n\(recorder.failures) failure(s)")
        exit(1)
    }
    print("\nall service-hours checks passed")
    }
}
