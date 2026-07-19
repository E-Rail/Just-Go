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
    case mapKit
}

struct TransitPlace {
    let name: String
    let coordinate: CLLocationCoordinate2D
    let address: String?
    let source: TransitPlaceSource

    init(
        name: String,
        coordinate: CLLocationCoordinate2D,
        address: String? = nil,
        source: TransitPlaceSource = .mapKit
    ) {
        self.name = name
        self.coordinate = coordinate
        self.address = address
        self.source = source
    }

    // Mirrors the app target's TransitPlace.id — StationQuickTag.placeIdentifier(for:)
    // builds place-tag identity from it.
    var id: String {
        "\(name)-\(String(format: "%.6f", coordinate.latitude))-\(String(format: "%.6f", coordinate.longitude))"
    }
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

private func testSingleSlotHomeWorkAndCanonicalOrder() throws {
    let tags = [
        tag("custom-new", kind: .custom("Gym")),
        tag("work-new", kind: .work),
        tag("home-new", kind: .home),
        tag("custom-old", kind: .custom("School")),
        tag("work-old", kind: .work),
        tag("home-old", kind: .home)
    ]
    let normalized = StationQuickTagPolicy.normalized(tags)
    try require(
        normalized.map(\.stationID) == ["home-new", "work-new", "custom-new", "custom-old"],
        "canonical order changed or single-slot Home/Work was not enforced"
    )
    try require(normalized.filter { $0.kind == .home }.count == 1, "Home must stay single-slot")
    try require(normalized.filter { $0.kind == .work }.count == 1, "Work must stay single-slot")
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
    try require(normalized.count == 3, "deduplication produced the wrong count")
    try require(normalized.filter { $0.stationID == "same" }.count == 1, "duplicate station survived")
    try require(normalized.contains { $0.kind == .custom("Newest") }, "newest station state did not win")
}

private func testUnlimitedCustomsSurviveNormalization() throws {
    let customs = (1...12).map { tag("custom-\($0)", kind: .custom("Tag \($0)")) }
    let normalized = StationQuickTagPolicy.normalized(customs)
    try require(
        normalized.map(\.stationID) == customs.map(\.stationID),
        "every custom tag must survive normalization in recency order"
    )
}

private func testUnlimitedCustomInsertion() throws {
    var tags = [
        tag("home", kind: .home),
        tag("work", kind: .work),
        tag("gym", kind: .custom("Gym"))
    ]
    for index in 1...10 {
        tags = StationQuickTagPolicy.inserting(tag("extra-\(index)", kind: .custom("Extra \(index)")), into: tags)
    }
    try require(tags.count == 13, "custom insertions must never be capped")
    try require(tags[0].stationID == "home", "Home must stay first")
    try require(tags[1].stationID == "work", "Work must stay second")
    try require(tags[2].stationID == "extra-10", "newest custom must lead the customs")
    try require(tags.last?.stationID == "gym", "oldest custom must survive at the end")
}

private func testLegacyStoredTagDecodesAsStation() throws {
    // A verbatim pre-place-support payload: no targetType, no address.
    let legacyJSON = """
    {"id":"8100|abc123","stationID":"abc123","name":"站 abc123","nameEn":"Station abc123",\
    "latitude":22,"longitude":114,"cityID":"8100","cityName":"香港","cityNameEn":"Hong Kong",\
    "lineNames":["東涌綫"],"lineNamesEn":["Tung Chung Line"],"lineIDs":["tcl"],\
    "lineColorsHex":["#F7943E"],"kind":{"home":{}}}
    """
    let decoded = try JSONDecoder().decode(StationQuickTag.self, from: Data(legacyJSON.utf8))
    try require(decoded.resolvedTargetType == .station, "legacy tags must resolve as station tags")
    try require(decoded.targetType == nil, "legacy tags must not invent a stored targetType")
    try require(decoded.address == nil, "legacy tags must not invent an address")
    try require(decoded.kind == .home, "legacy kind decoding changed")
}

private func testPlaceTagRoundTrip() throws {
    let place = TransitPlace(
        name: "Victoria Park",
        coordinate: CLLocationCoordinate2D(latitude: 22.28213, longitude: 114.18919),
        address: "1 Hing Fat Street, Causeway Bay"
    )
    let tag = StationQuickTag(
        place: place,
        cityID: "8100",
        cityName: "香港",
        cityNameEn: "Hong Kong",
        kind: .custom("Picnic")
    )
    try require(tag.resolvedTargetType == .place, "place tag must resolve as a place")
    try require(tag.stationID == StationQuickTag.placeIdentifier(for: place), "place identity drifted")
    try require(tag.lineNames.isEmpty, "place tags must not carry line data")
    try require(tag.address == place.address, "place address was dropped")

    let decoded = try JSONDecoder().decode(
        StationQuickTag.self,
        from: JSONEncoder().encode(tag)
    )
    try require(decoded == tag, "place tag did not survive a Codable round trip")
    try require(decoded.resolvedTargetType == .place, "decoded place tag lost its target type")
}

private func testExclusiveReassignment() throws {
    let current = [
        tag("home-old", kind: .home),
        tag("work", kind: .work),
        tag("gym", kind: .custom("Gym"))
    ]
    let newHome = tag("home-new", kind: .home)
    let updated = StationQuickTagPolicy.inserting(newHome, into: current)
    try require(updated.count == 3, "Home reassignment should reuse its exclusive slot")
    try require(updated.first?.id == newHome.id, "new Home did not replace the old Home")
    try require(updated.contains { $0.id == current[0].id } == false, "old Home survived reassignment")
}

@main
private enum QuickTagPolicyHarness {
    static func main() {
        do {
            try testSingleSlotHomeWorkAndCanonicalOrder()
            print("PASS: single-slot Home/Work and canonical order")
            try testNewestStationIdentityWins()
            print("PASS: newest station identity wins")
            try testUnlimitedCustomsSurviveNormalization()
            print("PASS: unlimited customs survive normalization")
            try testUnlimitedCustomInsertion()
            print("PASS: unlimited custom insertion")
            try testLegacyStoredTagDecodesAsStation()
            print("PASS: legacy stored tags decode as station tags")
            try testPlaceTagRoundTrip()
            print("PASS: place tag Codable round trip")
            try testExclusiveReassignment()
            print("PASS: exclusive Home reassignment")
            print("StationQuickTagPolicy: 7 test groups passed")
        } catch {
            FileHandle.standardError.write(Data("Quick Tag policy test failed: \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }
}
