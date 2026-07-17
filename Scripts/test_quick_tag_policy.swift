import CoreLocation
import Darwin
import Foundation

enum AppLocalization {
    static let isChinese = false
    static func localized(_ key: String) -> String { key }
    static func chinese(_ text: String) -> String { text }
    static func text(english: String, simplified: String, traditional: String) -> String { english }
}

struct SubwayLine {
    let lineID: String
    let name: String
    let nameEn: String?
    let colorHex: String
    let cityID: String
}

final class Station {
    let stationID: String
    let name: String
    let nameEn: String?
    let latitude: Double
    let longitude: Double
    let cityID: String
    var lines: [SubwayLine] = []

    init(
        stationID: String,
        name: String,
        nameEn: String?,
        latitude: Double,
        longitude: Double,
        cityID: String
    ) {
        self.stationID = stationID
        self.name = name
        self.nameEn = nameEn
        self.latitude = latitude
        self.longitude = longitude
        self.cityID = cityID
    }
}

enum TransitPlaceSource {
    case quickPlace
}

struct TransitPlace {
    let name: String
    let coordinate: CLLocationCoordinate2D
    let source: TransitPlaceSource
}

private struct HarnessFailure: Error, CustomStringConvertible {
    let description: String
}

private func require(
    _ condition: @autoclosure () -> Bool,
    _ message: @autoclosure () -> String,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    guard condition() else {
        throw HarnessFailure(description: "\(file):\(line): \(message())")
    }
}

private func tag(
    _ stationID: String,
    kind: StationQuickTagKind
) -> StationQuickTag {
    StationQuickTag(
        station: Station(
            stationID: stationID,
            name: "站 \(stationID)",
            nameEn: "Station \(stationID)",
            latitude: 22,
            longitude: 114,
            cityID: "8100"
        ),
        cityName: "香港",
        cityNameEn: "Hong Kong",
        kind: kind
    )
}

private func testThreeItemLimitAndCanonicalOrder() throws {
    let tags = [
        tag("custom-new", kind: .custom("Gym")),
        tag("work-new", kind: .work),
        tag("home-new", kind: .home),
        tag("custom-old", kind: .custom("School")),
        tag("work-old", kind: .work),
        tag("home-old", kind: .home)
    ]
    let normalized = StationQuickTagPolicy.normalized(tags)
    try require(StationQuickTagPolicy.maximumCount == 3, "maximum must be exactly three")
    try require(normalized.count == 3, "normalization exceeded three")
    try require(normalized.map(\.stationID) == ["home-new", "work-new", "custom-new"], "canonical order changed")
}

private func testNewestStationIdentityWins() throws {
    let newest = tag("same", kind: .custom("Newest"))
    let older = tag("same", kind: .home)
    let normalized = StationQuickTagPolicy.normalized([
        newest,
        tag("work", kind: .work),
        tag("custom", kind: .custom("Other")),
        older
    ])
    try require(normalized.count == 3, "deduplication changed the cap")
    try require(normalized.filter { $0.stationID == "same" }.count == 1, "duplicate station survived")
    try require(normalized.contains { $0.kind == .custom("Newest") }, "newest station state did not win")
}

private func testStableCustomRecency() throws {
    let normalized = StationQuickTagPolicy.normalized([
        tag("custom-1", kind: .custom("One")),
        tag("custom-2", kind: .custom("Two")),
        tag("custom-3", kind: .custom("Three")),
        tag("custom-4", kind: .custom("Four"))
    ])
    try require(
        normalized.map(\.stationID) == ["custom-1", "custom-2", "custom-3"],
        "custom recency was not stable"
    )
}

private func testCapacityAndReplacement() throws {
    let current = [
        tag("home", kind: .home),
        tag("work", kind: .work),
        tag("gym", kind: .custom("Gym"))
    ]
    let fourth = tag("school", kind: .custom("School"))
    try require(
        StationQuickTagPolicy.inserting(fourth, into: current) == nil,
        "a fourth tag must not mutate the collection without replacement"
    )
    try require(
        StationQuickTagPolicy.inserting(
            fourth,
            into: current,
            replacing: "8100|missing"
        ) == nil,
        "a stale replacement ID must not bypass capacity"
    )

    let replaced = StationQuickTagPolicy.inserting(
        fourth,
        into: current,
        replacing: current[2].id
    )
    try require(replaced?.count == 3, "explicit replacement changed the cap")
    try require(replaced?.contains { $0.id == fourth.id } == true, "new tag was not saved")
    try require(replaced?.contains { $0.id == current[2].id } == false, "selected tag survived replacement")
}

private func testExclusiveReassignment() throws {
    let current = [
        tag("home-old", kind: .home),
        tag("work", kind: .work),
        tag("gym", kind: .custom("Gym"))
    ]
    let newHome = tag("home-new", kind: .home)
    let updated = StationQuickTagPolicy.inserting(newHome, into: current)
    try require(updated?.count == 3, "Home reassignment should reuse its exclusive slot")
    try require(updated?.first?.id == newHome.id, "new Home did not replace the old Home")
    try require(updated?.contains { $0.id == current[0].id } == false, "old Home survived reassignment")
}

@main
private enum QuickTagPolicyHarness {
    static func main() {
        do {
            try testThreeItemLimitAndCanonicalOrder()
            print("PASS: exact three-item limit and Home/Work/custom order")
            try testNewestStationIdentityWins()
            print("PASS: newest station identity wins")
            try testStableCustomRecency()
            print("PASS: stable custom-tag recency")
            try testCapacityAndReplacement()
            print("PASS: fourth-tag rejection and explicit replacement")
            try testExclusiveReassignment()
            print("PASS: exclusive Home reassignment")
            print("StationQuickTagPolicy: 5 test groups passed")
        } catch {
            FileHandle.standardError.write(Data("Quick Tag policy test failed: \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }
}
