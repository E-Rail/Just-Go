import Darwin
import Foundation

private struct Failure: Error, CustomStringConvertible {
    let description: String
}

private func expect(_ condition: Bool, _ message: String) throws {
    if !condition { throw Failure(description: message) }
}

// The 顺义 shape: two network stations share a name, and the pack has a record for one of them.
private func testNamesakeDoesNotBorrowTheOtherStationsRecord() throws {
    let line15 = MetroStationIdentifier.qualified(cityID: "1100", stationID: "aaaa")
    let tongmi = MetroStationIdentifier.qualified(cityID: "1100", stationID: "bbbb")
    try expect(
        MetroStationIdentifier.nameMatch(forStationID: line15, mayUseRecordOf: "aaaa"),
        "a station must keep its own record"
    )
    try expect(
        !MetroStationIdentifier.nameMatch(forStationID: tongmi, mayUseRecordOf: "aaaa"),
        "a namesake borrowed the other station's record"
    )
    try expect(
        !MetroStationIdentifier.nameMatch(forStationID: tongmi, mayUseRecordOf: line15),
        "a qualified record ID was not compared by its canonical form"
    )
}

// Places and provider stops have no network ID, and some records are bound to no station: both
// still match by name, which is what the fallback is for.
private func testUnboundSidesStillMatchByName() throws {
    try expect(
        MetroStationIdentifier.nameMatch(forStationID: "official-1100-顺义", mayUseRecordOf: "aaaa"),
        "a place lost its name match"
    )
    try expect(
        MetroStationIdentifier.nameMatch(forStationID: nil, mayUseRecordOf: "aaaa"),
        "a lookup with no station ID lost its name match"
    )
    let station = MetroStationIdentifier.qualified(cityID: "1100", stationID: "bbbb")
    try expect(
        MetroStationIdentifier.nameMatch(forStationID: station, mayUseRecordOf: nil),
        "a record bound to no station was refused"
    )
    try expect(
        MetroStationIdentifier.nameMatch(forStationID: station, mayUseRecordOf: ""),
        "a record with an empty station ID was refused"
    )
}

@main
private enum StationIdentifierHarness {
    static func main() {
        do {
            try testNamesakeDoesNotBorrowTheOtherStationsRecord()
            print("PASS: a namesake does not borrow the other station's record")
            try testUnboundSidesStillMatchByName()
            print("PASS: places, providers and unbound records still match by name")
            print("MetroStationIdentifier: 2 test groups passed")
        } catch {
            FileHandle.standardError.write(Data("Station identifier test failed: \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }
}
