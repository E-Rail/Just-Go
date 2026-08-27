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

    var isNotYetStarted: Bool {
        if case .notYetStarted = self { return true }
        return false
    }

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
        "southbound is definitive",
        String(
            resolver.verdict(
                boardingLineName: "5号线",
                onwardStationNames: southbound,
                alightingStationName: "雍和宫",
                windows: tiantongyuannan,
                at: at(23, 20)
            ).isDefinitive
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
    // here as a nil/non-passing onward list. The old merged answer is still given — it is all there is —
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
        "...and says it is not safe to re-plan on",
        String(
            resolver.verdict(
                boardingLineName: "5号线",
                onwardStationNames: nil,
                alightingStationName: "雍和宫",
                windows: tiantongyuannan,
                at: at(23, 20)
            ).isDefinitive
        ),
        "false"
    )
    // A ring has no terminus to order stations against, so nothing on it is ever attributable.
    // 北京 2号线 and 10号线 are rings, and without the upper-bound rule they would be the two lines
    // a re-plan never fired for. Live windows for 西直门 on 2号线, 2026-08-25: every direction is
    // shut well before 23:36, so the merge — the latest of them — is shut too.
    let ringLine = [
        StationServiceWindow(lineName: "2号线", direction: "车公庄", firstTime: "5:10", lastTime: "22:14"),
        StationServiceWindow(lineName: "2号线", direction: "车公庄", firstTime: "5:10", lastTime: "22:59"),
        StationServiceWindow(lineName: "2号线", direction: "积水潭", firstTime: "5:05", lastTime: "22:59")
    ]
    check(
        "a ring with every direction shut is definitive",
        String(
            resolver.verdict(
                boardingLineName: "2号线",
                onwardStationNames: nil,
                alightingStationName: "雍和宫",
                windows: ringLine,
                at: at(23, 36)
            ).isDefinitive
        ),
        "true"
    )
    // ...but the same ring earlier in the evening is not, because "still running" out of a merge
    // may be the other direction's train.
    check(
        "a ring still inside the merged window is not",
        String(
            resolver.verdict(
                boardingLineName: "2号线",
                onwardStationNames: nil,
                alightingStationName: "雍和宫",
                windows: ringLine,
                at: at(22, 30)
            ).isDefinitive
        ),
        "false"
    )

    // One window is not a merge, so there is nothing to be optimistic about.
    check(
        "a lone window is definitive even with no onward list",
        String(
            resolver.verdict(
                boardingLineName: "5号线",
                onwardStationNames: nil,
                alightingStationName: "雍和宫",
                windows: [tiantongyuannan[0]],
                at: at(23, 20)
            ).isDefinitive
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

    // MARK: - The substring fallback that admitted the other direction
    //
    // Live from bjsubway.com …?accLocation=150995222 (国贸) on 2026-08-26. One fused line, four
    // services, and the two that matter here run in opposite directions:
    //   direction 1, toward 环球度假区   first 5:32  last 23:34
    //   direction 2, toward 苹果园       first 5:01  last 23:16
    //
    // The bundled pattern is 福寿岭 - 苹果园 - … - 国贸 - … - 果园 - … - 环球度假区, so an eastbound
    // rider has 苹果园 behind them and 果园 twenty-nine stops ahead. `"苹果园".contains("果园")` is
    // true, so the old containment fallback resolved the *westbound* window to the eastbound 果园
    // and admitted it as this rider's own service — pulling its 5:01 into the merge and marking the
    // result definitive. There are 158 such same-line pairs across 107 lines in 34 packs.

    let guomao = [
        StationServiceWindow(lineName: "1号线八通线", direction: "环球度假区", destination: "环球度假区", firstTime: "5:32", lastTime: "23:34"),
        StationServiceWindow(lineName: "1号线八通线", direction: "四惠东", destination: "四惠东", firstTime: "5:32", lastTime: "0:16"),
        StationServiceWindow(lineName: "1号线八通线", direction: "苹果园", destination: "苹果园", firstTime: "5:01", lastTime: "23:16"),
        StationServiceWindow(lineName: "1号线八通线", direction: "古城", destination: "古城", firstTime: "5:01", lastTime: "23:37")
    ]
    let guomaoEastbound = [
        "国贸", "大望路", "四惠", "四惠东", "高碑店", "传媒大学", "双桥", "管庄", "八里桥",
        "通州北苑", "果园", "九棵树", "梨园", "临河里", "土桥", "花庄", "环球度假区"
    ]

    print("国贸 1号线/八通线 — the 苹果园 ⊃ 果园 trap")
    // At 5:15 the eastbound first train (5:32) has not left. Borrowing the westbound 5:01 said it had.
    check(
        "eastbound at 5:15 is before its own first train",
        resolver.verdict(
            boardingLineName: "1号线/八通线",
            onwardStationNames: guomaoEastbound,
            alightingStationName: "传媒大学",
            windows: guomao,
            at: at(5, 15)
        ).status.label,
        "notYetStarted(5:32)"
    )
    // The short-turn to 四惠东 turns back before 传媒大学, so its 0:16 is not this rider's last train.
    check(
        "eastbound past the short-turn is judged by the full run",
        resolver.verdict(
            boardingLineName: "1号线/八通线",
            onwardStationNames: guomaoEastbound,
            alightingStationName: "传媒大学",
            windows: guomao,
            at: at(23, 45)
        ).status.label,
        "serviceEnded"
    )
    // ...but a rider who only goes as far as 四惠东 can still catch it.
    check(
        "eastbound to the short-turn's own terminus is still running",
        resolver.verdict(
            boardingLineName: "1号线/八通线",
            onwardStationNames: guomaoEastbound,
            alightingStationName: "四惠东",
            windows: guomao,
            at: at(23, 45)
        ).status.label,
        "running"
    )

    // MARK: - Three services under one direction marker
    //
    // Same station, 10号线, same fetch. Every northbound row carries terminalStationName 双井; only
    // destStationName separates them:
    //   → 车道沟  5:18 – 21:28      → 成寿寺  5:18 – 23:36      → 巴沟  5:18 – 23:12
    // Keying on the direction marker alone collapsed these to one 23:36 window. 成寿寺 is seventeen
    // stops short of 车道沟, so that 23:36 belongs to a train that turns back long before this rider
    // gets off: their real last train is the 23:12 to 巴沟, which carries on round the ring past
    // 车道沟. Twenty-four minutes, in the direction that leaves someone on a closed platform.

    let guomaoLine10 = [
        StationServiceWindow(lineName: "10号线", direction: "双井", destination: "车道沟", firstTime: "5:18", lastTime: "21:28"),
        StationServiceWindow(lineName: "10号线", direction: "双井", destination: "成寿寺", firstTime: "5:18", lastTime: "23:36"),
        StationServiceWindow(lineName: "10号线", direction: "双井", destination: "巴沟", firstTime: "5:18", lastTime: "23:12")
    ]
    // 10号线 is a ring; this is the northbound arc as the graph would hand it over.
    let line10Onward = ["国贸", "双井", "劲松", "潘家园", "十里河", "成寿寺", "分钟寺", "大红门", "石榴庄", "角门东", "角门西", "草桥", "纪家庙", "首经贸", "丰台站", "泥洼", "西局", "六里桥", "莲花桥", "公主坟", "西钓鱼台", "慈寿寺", "车道沟", "长春桥", "火器营", "巴沟"]

    print("国贸 10号线 — three services, one direction marker")
    // 23:12 is the answer, so at 23:20 the platform is dark — the merged 23:36 said otherwise.
    check(
        "to 车道沟, after the last train that actually reaches it",
        resolver.verdict(
            boardingLineName: "10号线",
            onwardStationNames: line10Onward,
            alightingStationName: "车道沟",
            windows: guomaoLine10,
            at: at(23, 20)
        ).status.label,
        "serviceEnded"
    )
    // The same moment, a stop the 23:36 short-turn does reach.
    check(
        "to 成寿寺, which the 23:36 short-turn does reach",
        resolver.verdict(
            boardingLineName: "10号线",
            onwardStationNames: line10Onward,
            alightingStationName: "成寿寺",
            windows: guomaoLine10,
            at: at(23, 20)
        ).status.label,
        "lastTrainSoon(16)"
    )

    // MARK: - No line match is no answer, not somebody else's answer
    //
    // 西直门 carries 2号线, 4号线 and 13号线. When the pack and the operator spell a line differently
    // — 首都机场线 against 机场线 share no reference — the pool used to fall back to *every* window at
    // the station, and a single-row fallback was even marked definitive.

    print("cross-line contamination")
    check(
        "an unmatched line is unanswered, not judged by its neighbours",
        resolver.verdict(
            boardingLineName: "首都机场线",
            onwardStationNames: nil,
            alightingStationName: nil,
            windows: [StationServiceWindow(lineName: "13号线", direction: "东直门", firstTime: "5:30", lastTime: "22:40")],
            at: at(23, 30)
        ).status.label,
        "unknown"
    )

    // MARK: - A last train with no first train
    //
    // Hangzhou nulls placeholder times per field and Beijing's own merge can leave either side
    // empty, so these arrive regularly. Reporting `unknown` withheld the one fact the feature is for.

    let lastOnly = [StationServiceWindow(lineName: "1号线", direction: "湘湖", firstTime: nil, lastTime: "23:12")]
    print("a row with only a last train")
    check(
        "shortly before it, the countdown still fires",
        resolver.verdict(
            boardingLineName: "1号线",
            onwardStationNames: nil,
            alightingStationName: nil,
            windows: lastOnly,
            at: at(23, 0)
        ).status.label,
        "lastTrainSoon(12)"
    )
    check(
        "shortly after it, service has ended",
        resolver.verdict(
            boardingLineName: "1号线",
            onwardStationNames: nil,
            alightingStationName: nil,
            windows: lastOnly,
            at: at(23, 40)
        ).status.label,
        "serviceEnded"
    )
    // At breakfast the last train says nothing about today, and guessing is how this got wrong.
    check(
        "hours later it claims nothing",
        resolver.verdict(
            boardingLineName: "1号线",
            onwardStationNames: nil,
            alightingStationName: nil,
            windows: lastOnly,
            at: at(8, 0)
        ).status.label,
        "unknown"
    )

    // MARK: - Banning the shut direction, not the shut line
    //
    // The verdict is reached from the rider's own onward stations, so it speaks for the way they
    // are travelling and nothing else. 天通苑南 southbound on 5号线 finishes at 22:51 while
    // northbound runs to 23:57; excluding the line banned a train that was still running, at the
    // hour when there are fewest of them left.

    let line5 = [["a", "b", "c", "d", "e"]]
    print("directed hops")
    let shutDirection = directedHops(lineID: "5", from: "b", to: "c", patterns: line5, identify: { $0 })
    check(
        "one observed hop expands to the whole direction",
        shutDirection.sorted { $0.fromStationID < $1.fromStationID }
            .map { "\($0.fromStationID)>\($0.toStationID)" }.joined(separator: ","),
        "a>b,b>c,c>d,d>e"
    )
    check(
        "and leaves the opposite direction alone",
        String(shutDirection.contains(DirectedServiceHop(lineID: "5", fromStationID: "c", toStationID: "b"))),
        "false"
    )
    // A branch that does not contain both stations says nothing about which way the rider is going.
    // Guessing would ban the arm they could still use; 24 bundled lines genuinely branch.
    let branching = [["trunk", "junction", "west1", "west2"], ["trunk", "junction", "east1", "east2"]]
    let westbound = directedHops(lineID: "9", from: "junction", to: "west1", patterns: branching, identify: { $0 })
    check(
        "an unrelated branch is not banned",
        String(westbound.contains(DirectedServiceHop(lineID: "9", fromStationID: "junction", toStationID: "east1"))),
        "false"
    )
    check(
        "...while the shared trunk in that direction is",
        String(westbound.contains(DirectedServiceHop(lineID: "9", fromStationID: "trunk", toStationID: "junction"))),
        "true"
    )
    check(
        "a hop the line does not make expands to nothing",
        String(directedHops(lineID: "5", from: "a", to: "zz", patterns: line5, identify: { $0 }).count),
        "0"
    )

    if recorder.failures > 0 {
        print("\n\(recorder.failures) failure(s)")
        exit(1)
    }
    print("\nall service-hours checks passed")
    }
}
