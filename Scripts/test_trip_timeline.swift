import Darwin
import Foundation

private struct Failure: Error, CustomStringConvertible {
    let description: String
}

private func expect(_ condition: Bool, _ message: String) throws {
    if !condition { throw Failure(description: message) }
}

// One degree of latitude is 110,540 m in the timeline's frame, so 0.01° is a 1,105 m hop.
private func north(_ metres: Double, from point: TimelinePoint) -> TimelinePoint {
    TimelinePoint(latitude: point.latitude + metres / 110_540, longitude: point.longitude)
}

private func east(_ metres: Double, from point: TimelinePoint) -> TimelinePoint {
    let metresPerDegree = 111_320 * cos(point.latitude * .pi / 180)
    return TimelinePoint(latitude: point.latitude, longitude: point.longitude + metres / metresPerDegree)
}

private let home = TimelinePoint(latitude: 39.9, longitude: 116.4)
private let stopA = north(750, from: home)
private let stopB = north(1_100, from: stopA)
private let stopC = north(1_100, from: stopB)
private let stopD = north(1_100, from: stopC)
private let stopE = east(1_200, from: stopD)
private let stopF = east(1_200, from: stopE)
private let office = east(400, from: stopF)
private let start = Date(timeIntervalSince1970: 1_800_000_000)

/// Walk 600 s, ride A→D (180 s to board, 120 s a hop), change for 420 s, ride D→F (150 s a hop),
/// walk 300 s, arrive.
private func trip() -> TripTimeline {
    TripTimeline(
        steps: [
            TimelineStep(kind: .access, duration: 600, path: [home, stopA]),
            TimelineStep(
                kind: .ride,
                duration: 540,
                stops: [
                    TimelineStop(name: "A", point: stopA, offset: 0),
                    TimelineStop(name: "B", point: stopB, offset: 120),
                    TimelineStop(name: "C", point: stopC, offset: 240),
                    TimelineStop(name: "D", point: stopD, offset: 360)
                ],
                boarding: 180
            ),
            TimelineStep(kind: .transfer, duration: 420),
            TimelineStep(
                kind: .ride,
                duration: 300,
                stops: [
                    TimelineStop(name: "D", point: stopD, offset: 0),
                    TimelineStop(name: "E", point: stopE, offset: 150),
                    TimelineStop(name: "F", point: stopF, offset: 300)
                ]
            ),
            TimelineStep(kind: .access, duration: 300, path: [stopF, office]),
            TimelineStep(kind: .arrive, duration: 0)
        ],
        startedAt: start
    )
}

private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

private func fix(_ point: TimelinePoint, accuracy: Double = 20, at seconds: TimeInterval) -> TripFix {
    TripFix(point: point, accuracy: accuracy, date: at(seconds))
}

private func testTheClockCarriesTheTripAndSaysItIsEstimating() throws {
    let timeline = trip()
    let begun = timeline.position(at: at(0))
    try expect(begun.stepIndex == 0 && begun.basis == .confirmed, "a new trip must start at its first step, on the rider's word")

    let boarding = timeline.position(at: at(700))
    try expect(boarding.stepIndex == 1, "the clock did not carry the trip into the ride")
    try expect(boarding.basis == .estimated, "a step only the clock reached must read as estimated")
    try expect(boarding.stopsRemaining == 3 && boarding.nextStopName == "B", "a train that has not left has every stop ahead")
    try expect(!boarding.departureKnown, "nobody said when the train left")

    // 600 walked, 180 to board, 130 riding: past B, before C.
    let riding = timeline.position(at: at(910))
    try expect(riding.stopsRemaining == 2 && riding.nextStopName == "C", "the stop count did not run with the clock")

    let ended = timeline.position(at: at(100_000))
    try expect(ended.stepIndex == 5 && timeline.hasArrived(at: at(100_000)), "the clock must stop at the last step")
}

private func testAWalkFollowsTheFixNotTheClock() throws {
    var timeline = trip()
    try expect(timeline.observe(fix(north(375, from: home), at: 100), now: at(100)), "a fix on the path was ignored")
    try expect(abs(timeline.anchor.elapsed - 300) < 1, "half the path must read as half the walk")
    try expect(timeline.position(at: at(100)).basis == .located, "a fix must read as located")

    // Standing still for ten minutes, with fixes: the clock alone would have boarded the train.
    for second in stride(from: 110.0, through: 700, by: 10) {
        timeline.observe(fix(north(375, from: home), at: second), now: at(second))
    }
    try expect(timeline.position(at: at(700)).stepIndex == 0, "a rider still on the street was put on the train")

    try expect(timeline.observe(fix(north(730, from: home), at: 710), now: at(710)), "arriving was ignored")
    let arrived = timeline.position(at: at(710))
    try expect(arrived.stepIndex == 1 && arrived.basis == .located, "reaching the path's end must start the next step")
}

private func testATightFixOffEveryPathHoldsTheWalk() throws {
    var timeline = trip()
    let elsewhere = east(300, from: north(300, from: home))
    for second in stride(from: 10.0, through: 900, by: 10) {
        timeline.observe(fix(elsewhere, at: second), now: at(second))
    }
    try expect(timeline.position(at: at(900)).stepIndex == 0, "a walk ended by the clock while fixes put the rider elsewhere")

    // The rider boarded one stop up the line instead. A satellite fix there is above ground and is
    // believed, however far ahead of the estimate it is; the same place from Wi-Fi is not.
    try expect(!timeline.observe(fix(stopB, accuracy: 65, at: 910), now: at(910)), "a loose fix far ahead of the estimate was believed")
    try expect(timeline.observe(fix(stopB, accuracy: 10, at: 920), now: at(920)), "a satellite fix at a later stop was refused")
    let aboard = timeline.position(at: at(920))
    try expect(aboard.stepIndex == 1 && aboard.stopsRemaining == 2, "the trip did not move onto the ride")
}

private func testAnotherDoorIntoTheStationEndsTheWalk() throws {
    var timeline = trip()
    // 120 m from the station and 110 m off the planned path: not the door the plan chose.
    let otherDoor = east(110, from: north(700, from: home))
    try expect(timeline.observe(fix(otherDoor, at: 500), now: at(500)), "reaching the station by another door was ignored")
    try expect(timeline.anchor.stepIndex == 1 && timeline.anchor.elapsed == 0, "the walk did not end at the station")
}

private func testFixesAtTheBoardingStationHoldTheTrainForALimitedTime() throws {
    var timeline = trip()
    timeline.observe(fix(north(740, from: home), at: 600), now: at(600))
    try expect(timeline.anchor.stepIndex == 1 && timeline.anchor.elapsed == 0, "the ride did not start at the entrance")

    // Four minutes in the station: past the 180 s the model allows, and still at stop A.
    try expect(timeline.observe(fix(stopA, accuracy: 120, at: 840), now: at(840)), "a boarding-station fix was ignored")
    try expect(timeline.anchor.elapsed == 180, "a rider still at the boarding station must be held at departure")
    try expect(!timeline.position(at: at(840)).departureKnown, "a held train has not left")

    timeline.observe(fix(stopA, accuracy: 120, at: 1_100), now: at(1_100))
    try expect(timeline.anchor.date == at(1_100), "the hold must last while it is inside its limit")
    try expect(!timeline.observe(fix(stopA, accuracy: 120, at: 1_300), now: at(1_300)), "a boarding hold ran past its limit")
}

private func testTheRidersWordIsNotWalkedBack() throws {
    var timeline = trip()
    timeline.confirm(stepIndex: 1, at: at(700))
    try expect(timeline.anchor.elapsed == 180, "Next onto a ride must mean the train is leaving")
    let boarded = timeline.position(at: at(700))
    try expect(boarded.basis == .confirmed && boarded.departureKnown, "a confirmed boarding must read as known")
    try expect(!timeline.observe(fix(stopA, accuracy: 120, at: 720), now: at(720)), "a boarding-station fix undid the rider's word")

    // And the rider can always go back.
    timeline.confirm(stepIndex: 0, at: at(800))
    try expect(timeline.position(at: at(800)).stepIndex == 0, "Back did not go back")
}

private func testAStationFixCorrectsTheRide() throws {
    var timeline = trip()
    timeline.confirm(stepIndex: 1, at: at(700))

    // The model has the train at C after 240 s. It is there after 200.
    try expect(timeline.observe(fix(stopC, accuracy: 150, at: 900), now: at(900)), "a station fix was ignored")
    let located = timeline.position(at: at(900))
    try expect(located.stopsRemaining == 1 && located.nextStopName == "D", "the fix did not set the stop count")
    try expect(located.basis == .located && located.departureKnown, "a stop reached by a fix must read as located")

    try expect(!timeline.observe(fix(stopC, accuracy: 150, at: 920), now: at(920)), "the same stop twice held the train through its dwell")
    try expect(!timeline.observe(fix(stopB, accuracy: 150, at: 930), now: at(930)), "a ride ran backwards")

    let between = north(550, from: stopC)
    try expect(!timeline.observe(fix(between, accuracy: 150, at: 950), now: at(950)), "a fix between two stops named one of them")
    try expect(!timeline.observe(fix(stopD, accuracy: 350, at: 1_000), now: at(1_000)), "a fix too loose to name a stop was used")
}

private func testAStopTooFarFromTheEstimateIsRefused() throws {
    var ahead = trip()
    ahead.confirm(stepIndex: 1, at: at(700))
    // Ten seconds after leaving, a fix at the last stop: 350 s ahead of the clock.
    try expect(!ahead.observe(fix(stopD, accuracy: 100, at: 710), now: at(710)), "a stop far ahead of the estimate was accepted")

    var behind = trip()
    behind.confirm(stepIndex: 1, at: at(700))
    // By the clock the train reached D at 1,060 and the change is under way. B is 420 s behind.
    try expect(!behind.observe(fix(stopB, accuracy: 100, at: 1_240), now: at(1_240)), "a stop far behind the estimate was accepted")
    // C is 300 s behind 1,240: inside the window, and the estimate comes back to it.
    try expect(behind.observe(fix(stopC, accuracy: 100, at: 1_240), now: at(1_240)), "a stop inside the window was refused")
    try expect(behind.position(at: at(1_240)).stepIndex == 1, "the estimate was not brought back to the observed stop")
}

private func testAChangeIsNotSkippedByStandingInTheStation() throws {
    var timeline = trip()
    timeline.confirm(stepIndex: 1, at: at(700))
    try expect(timeline.observe(fix(stopD, accuracy: 100, at: 1_050), now: at(1_050)), "arriving at the last stop was ignored")
    try expect(timeline.anchor.stepIndex == 2 && timeline.anchor.elapsed == 0, "the last stop must start the change")

    // D is also where the next ride boards. Being there mid-change says nothing.
    try expect(!timeline.observe(fix(stopD, accuracy: 100, at: 1_150), now: at(1_150)), "standing in the station ended the change")
    try expect(timeline.position(at: at(1_150)).stepIndex == 2, "the change was skipped")

    // Once the clock has the rider on the second ride, the same fix holds its departure.
    try expect(timeline.observe(fix(stopD, accuracy: 100, at: 1_500), now: at(1_500)), "a boarding hold after a change was ignored")
    try expect(timeline.anchor.stepIndex == 3 && timeline.anchor.elapsed == 0, "the second ride was not held at its start")
}

private func testComingBackAboveGroundFindsTheTrip() throws {
    var timeline = trip()
    timeline.confirm(stepIndex: 1, at: at(700))
    // Nothing underground, then a tight fix on the last walk.
    let onTheLastWalk = east(200, from: stopF)
    try expect(timeline.observe(fix(onTheLastWalk, at: 1_800), now: at(1_800)), "a fix on the last walk was ignored")
    let surfaced = timeline.position(at: at(1_800))
    try expect(surfaced.stepIndex == 4 && surfaced.basis == .located, "the trip did not jump to where the rider is")

    try expect(timeline.observe(fix(east(390, from: stopF), at: 1_900), now: at(1_900)), "arriving was ignored")
    try expect(timeline.hasArrived(at: at(1_900)), "reaching the destination must end the trip")
    try expect(timeline.position(at: at(1_900)).basis == .located, "an observed arrival must read as located")
}

private func testFixesThatProveNothingAreIgnored() throws {
    var timeline = trip()
    try expect(!timeline.observe(fix(north(375, from: home), accuracy: -1, at: 100), now: at(100)), "an invalid fix was used")
    try expect(!timeline.observe(fix(north(375, from: home), at: 100), now: at(200)), "a stale fix was used")
    try expect(!timeline.observe(fix(north(375, from: home), accuracy: 90, at: 100), now: at(100)), "a loose fix moved a walk")
    timeline.confirm(stepIndex: 1, at: at(300))
    try expect(!timeline.observe(fix(north(375, from: home), at: 290), now: at(301)), "a fix older than the rider's word overruled it")
}

private func testAlertsCoverEveryRideAndMoveWithTheAnchor() throws {
    var timeline = trip()
    let planned = timeline.alerts(before: 120)
    try expect(planned.map(\.stepIndex) == [1, 3], "every ride must have an alert")
    try expect(planned.map(\.stationName) == ["D", "F"], "an alert must name the stop to get off at")
    // 600 + 540 − 120, then 600 + 540 + 420 + 300 − 120.
    try expect(planned.map(\.fireDate) == [at(1_020), at(1_740)], "alert times do not follow the modelled trip")

    timeline.confirm(stepIndex: 1, at: at(900))
    // Boarded at 900: 360 s of riding, less the lead.
    try expect(timeline.alerts(before: 120).first?.fireDate == at(1_140), "an alert did not move with the anchor")

    timeline.confirm(stepIndex: 3, at: at(2_000))
    try expect(timeline.alerts(before: 120).map(\.stepIndex) == [3], "a finished ride must have no alert")
}

private func testASavedAnchorIsRestoredAndAForeignOneIsNot() throws {
    let steps = trip().steps
    let saved = TripAnchor(stepIndex: 3, elapsed: 150, date: at(2_000), basis: .located)
    let restored = TripTimeline(steps: steps, anchor: saved, restoredAt: at(2_010))
    try expect(restored.position(at: at(2_010)).stepIndex == 3, "a saved position was not restored")

    let foreign = TripAnchor(stepIndex: 9, elapsed: 0, date: at(2_000), basis: .located)
    let restarted = TripTimeline(steps: steps, anchor: foreign, restoredAt: at(2_010))
    try expect(restarted.position(at: at(2_010)).stepIndex == 0, "an anchor for another trip was applied")

    let coded = try JSONDecoder().decode(TripAnchor.self, from: JSONEncoder().encode(saved))
    try expect(coded == saved, "an anchor did not survive being saved")
}

private func testProjectionMeasuresOffAndAlong() throws {
    let path = [home, north(400, from: home), east(300, from: north(400, from: home))]
    guard let projection = TimelineGeometry.project(east(30, from: north(100, from: home)), onto: path) else {
        throw Failure(description: "a point beside a path did not project")
    }
    try expect(abs(projection.distance - 30) < 1, "distance off the path is wrong")
    try expect(abs(projection.along - 100) < 1, "distance along the path is wrong")
    try expect(abs(projection.length - 700) < 1, "the path's length is wrong")
    try expect(TimelineGeometry.project(home, onto: [home]) == nil, "a single point is not a path")
}

@main
private enum TripTimelineHarness {
    static func main() {
        let tests: [(String, () throws -> Void)] = [
            ("the clock carries the trip and says it is estimating", testTheClockCarriesTheTripAndSaysItIsEstimating),
            ("a walk follows the fix, not the clock", testAWalkFollowsTheFixNotTheClock),
            ("a tight fix off every path holds the walk", testATightFixOffEveryPathHoldsTheWalk),
            ("another door into the station ends the walk", testAnotherDoorIntoTheStationEndsTheWalk),
            ("boarding-station fixes hold the train for a limited time", testFixesAtTheBoardingStationHoldTheTrainForALimitedTime),
            ("the rider's word is not walked back", testTheRidersWordIsNotWalkedBack),
            ("a station fix corrects the ride", testAStationFixCorrectsTheRide),
            ("a stop too far from the estimate is refused", testAStopTooFarFromTheEstimateIsRefused),
            ("a change is not skipped by standing in the station", testAChangeIsNotSkippedByStandingInTheStation),
            ("coming back above ground finds the trip", testComingBackAboveGroundFindsTheTrip),
            ("fixes that prove nothing are ignored", testFixesThatProveNothingAreIgnored),
            ("alerts cover every ride and move with the anchor", testAlertsCoverEveryRideAndMoveWithTheAnchor),
            ("a saved anchor is restored and a foreign one is not", testASavedAnchorIsRestoredAndAForeignOneIsNot),
            ("projection measures off and along", testProjectionMeasuresOffAndAlong)
        ]
        do {
            for (name, test) in tests {
                try test()
                print("PASS: \(name)")
            }
            print("TripTimeline: \(tests.count) test groups passed")
        } catch {
            FileHandle.standardError.write(Data("Trip timeline test failed: \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }
}
