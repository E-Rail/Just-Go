import Foundation

/// How the app knows where the rider is on a trip. Shown beside every position: an observation and
/// an estimate read the same on screen and are not the same claim.
enum TripBasis: String, Codable, Sendable {
    /// A location fix placed the rider.
    case located
    /// The rider said so: Back, Next, or "I'm on the train".
    case confirmed
    /// Only the clock: modelled durations counted on from the last anchor.
    case estimated
}

/// A coordinate in the map's frame (GCJ-02), as every route's geometry is.
struct TimelinePoint: Codable, Equatable, Sendable {
    let latitude: Double
    let longitude: Double

    /// Flat-earth metres: exact enough at walking and station scale.
    func distance(to other: TimelinePoint) -> Double {
        let metresPerDegreeLatitude = 110_540.0
        let metresPerDegreeLongitude = 111_320.0 * cos(latitude * .pi / 180)
        let dx = (other.longitude - longitude) * metresPerDegreeLongitude
        let dy = (other.latitude - latitude) * metresPerDegreeLatitude
        return (dx * dx + dy * dy).squareRoot()
    }
}

enum TimelineGeometry {
    /// Where a point falls against a path: how far off it is, and how far along it.
    struct Projection: Equatable, Sendable {
        let distance: Double
        let along: Double
        let length: Double
    }

    /// Point-to-segment projections in a small local planar frame.
    static func project(_ point: TimelinePoint, onto path: [TimelinePoint]) -> Projection? {
        guard path.count >= 2 else { return nil }
        var best = Double.greatestFiniteMagnitude
        var bestAlong = 0.0
        var travelled = 0.0
        for index in 0..<(path.count - 1) {
            let a = path[index]
            let b = path[index + 1]
            let metresPerDegreeLongitude = 111_320.0 * cos(a.latitude * .pi / 180)
            let metresPerDegreeLatitude = 110_540.0
            let bx = (b.longitude - a.longitude) * metresPerDegreeLongitude
            let by = (b.latitude - a.latitude) * metresPerDegreeLatitude
            let px = (point.longitude - a.longitude) * metresPerDegreeLongitude
            let py = (point.latitude - a.latitude) * metresPerDegreeLatitude
            let lengthSquared = bx * bx + by * by
            let t = lengthSquared == 0 ? 0 : min(1, max(0, (px * bx + py * by) / lengthSquared))
            let qx = t * bx, qy = t * by
            let distance = ((px - qx) * (px - qx) + (py - qy) * (py - qy)).squareRoot()
            let length = lengthSquared.squareRoot()
            if distance < best {
                best = distance
                bestAlong = travelled + t * length
            }
            travelled += length
        }
        return Projection(distance: best, along: bestAlong, length: travelled)
    }
}

/// One stop of a ride, boarding stop first.
struct TimelineStop: Equatable, Sendable {
    let name: String
    let point: TimelinePoint?
    /// Seconds from the train leaving the boarding stop to arriving here. Zero for the boarding stop.
    let offset: TimeInterval
}

/// One step of a trip as the clock and a location fix see it. One per `TripStep`, in order.
struct TimelineStep: Equatable, Sendable {
    enum Kind: Sendable {
        /// A walk, a bike ride or a drive along a path on the ground.
        case access
        case ride
        case transfer
        case arrive
    }

    let kind: Kind
    /// The whole step, `boarding` included.
    let duration: TimeInterval
    /// `.access`: the path on the ground, in order.
    var path: [TimelinePoint] = []
    /// `.ride`: every stop, boarding stop first.
    var stops: [TimelineStop] = []
    /// `.ride`: seconds between reaching the station and the train leaving. A transfer's allowance
    /// already carries this, so only a ride entered from the street has one.
    var boarding: TimeInterval = 0
}

/// The last thing known about where the rider is. Only an observation or the rider's own word
/// writes one; the clock reads it and never moves it.
struct TripAnchor: Codable, Equatable, Sendable {
    var stepIndex: Int
    /// Seconds into the step at `date`.
    var elapsed: TimeInterval
    var date: Date
    /// `.located` or `.confirmed`.
    var basis: TripBasis
    /// When fixes first said the rider was still at this ride's boarding station.
    var holdStartedAt: Date? = nil
}

/// A fix in the map's frame.
struct TripFix: Equatable, Sendable {
    let point: TimelinePoint
    /// Metres; negative is invalid, as Core Location reports it.
    let accuracy: Double
    let date: Date
}

struct TripPosition: Equatable, Sendable {
    let stepIndex: Int
    let basis: TripBasis
    let stepStartedAt: Date
    let stepEndsAt: Date
    /// Ride steps: stops still ahead, the rider's own included.
    let stopsRemaining: Int?
    /// Ride steps: the stop the train reaches next.
    let nextStopName: String?
    /// Ride steps: whether the moment the train left is known, from the rider or from a fix at a
    /// later stop. Until then the stop count runs from an assumed departure.
    let departureKnown: Bool
}

/// When to tell the rider to get ready, for one ride.
struct TripAlert: Equatable, Sendable {
    let stepIndex: Int
    let fireDate: Date
    let stationName: String
}

/// What to change in the alerts the system holds for a trip, worked out from what it holds now.
struct TripAlertPlan: Equatable, Sendable {
    /// What is held once the plan is carried out. An entry whose time has come has been given.
    var held: [TripAlert] = []
    /// To hand to the system. Each takes the place of whatever is held for its ride, and one dated
    /// now is to be given at once.
    var schedule: [TripAlert] = []
    /// Rides whose alert is withdrawn.
    var cancel: [Int] = []
    /// A ride a fix has put the rider at the end of before its alert came. Given at once and in
    /// its own words: it is an observation, where every other alert is an estimate.
    var reached: TripAlert?
}

/// A trip that moves on its own. The clock carries the position forward from the anchor, a fix
/// corrects it, and the rider can always overrule both.
///
/// The thresholds below are first values. No field data on what a phone reports in a tunnel exists
/// yet, so each errs towards an early alert: an early one costs a minute of standing, a late one
/// costs the stop.
struct TripTimeline: Equatable, Sendable {
    /// A fix this tight on the ground is the rider, not a guess at them.
    static let accessFixAccuracy = 65.0
    /// How far from the path still counts as on it: the corridor off-route detection uses.
    static let accessCorridor = 100.0
    /// How close to the path's end counts as there.
    static let accessArrivalRadius = 40.0
    /// Only satellites report this tightly, and there are none underground: a fix this good is
    /// above ground and is believed over the estimate, however far apart they are.
    static let satelliteFixAccuracy = 25.0
    /// Station fixes come from Wi-Fi and cell, and are looser than GPS.
    static let rideFixAccuracy = 200.0
    /// How close to a station counts as having reached it by a door the plan did not choose.
    static let stationArrivalRadius = 150.0
    /// Past this a fix says "somewhere near the line", not "at this stop".
    static let rideStopRadius = 400.0
    static let maximumFixAge: TimeInterval = 20
    /// How far a station fix may move the estimate. A stop further off than this, in either
    /// direction, is more likely a wrong fix (a train's own Wi-Fi keeps one registered address)
    /// than a train that ran that differently from the model.
    static let ridePlausibilityAhead: TimeInterval = 240
    static let ridePlausibilityBehind: TimeInterval = 300
    /// How long fixes at the boarding station may hold the train back. Bounded, because a stale
    /// fix that never changes would otherwise delay every alert on the ride.
    static let boardingHoldLimit: TimeInterval = 360
    /// From the gate line to a moving train: stairs, the platform and a wait no pack publishes.
    static let boardingAllowance: TimeInterval = 180

    let steps: [TimelineStep]
    private(set) var anchor: TripAnchor

    /// A trip the rider has just started: at the first step, on their own word.
    init(steps: [TimelineStep], startedAt date: Date) {
        self.steps = steps
        self.anchor = TripAnchor(stepIndex: 0, elapsed: 0, date: date, basis: .confirmed)
    }

    /// A trip picked up again. An anchor that names a step this trip does not have starts over.
    init(steps: [TimelineStep], anchor: TripAnchor, restoredAt date: Date) {
        self.steps = steps
        self.anchor = steps.indices.contains(anchor.stepIndex)
            ? anchor
            : TripAnchor(stepIndex: 0, elapsed: 0, date: date, basis: .confirmed)
    }

    // MARK: - Reading

    func position(at now: Date) -> TripPosition {
        let clock = clockPosition(at: now)
        guard steps.indices.contains(clock.stepIndex) else {
            return TripPosition(
                stepIndex: 0, basis: .estimated, stepStartedAt: now, stepEndsAt: now,
                stopsRemaining: nil, nextStopName: nil, departureKnown: false
            )
        }
        let step = steps[clock.stepIndex]
        let passed = stopsPassed(in: step, elapsed: clock.elapsed)
        // The anchor still describes the rider while the clock has moved neither the step nor the
        // stop count on from it.
        let unchanged = clock.stepIndex == anchor.stepIndex
            && passed == stopsPassed(in: step, elapsed: anchor.elapsed)
        let lastStop = step.stops.count - 1
        return TripPosition(
            stepIndex: clock.stepIndex,
            basis: unchanged ? anchor.basis : .estimated,
            stepStartedAt: clock.startedAt,
            stepEndsAt: clock.startedAt.addingTimeInterval(step.duration),
            stopsRemaining: step.kind == .ride && lastStop > 0 ? lastStop - passed : nil,
            nextStopName: step.kind == .ride && passed < lastStop ? step.stops[passed + 1].name : nil,
            departureKnown: step.kind == .ride && departureKnown(ofRide: clock.stepIndex)
        )
    }

    /// When the trip ends by the model's own clock, counted on from the anchor.
    var estimatedEnd: Date {
        guard steps.indices.contains(anchor.stepIndex) else { return anchor.date }
        let remaining = steps[anchor.stepIndex...].reduce(0) { $0 + $1.duration } - anchor.elapsed
        return anchor.date.addingTimeInterval(max(0, remaining))
    }

    /// Whether the last step has been reached, by any basis.
    func hasArrived(at now: Date) -> Bool {
        !steps.isEmpty && clockPosition(at: now).stepIndex == steps.count - 1
    }

    /// Every ride's "get ready" moment from here on: `before` seconds ahead of its last stop.
    func alerts(before: TimeInterval) -> [TripAlert] {
        guard steps.indices.contains(anchor.stepIndex) else { return [] }
        var alerts: [TripAlert] = []
        var stepStart = anchor.date.addingTimeInterval(-anchor.elapsed)
        for index in anchor.stepIndex..<steps.count {
            let step = steps[index]
            if step.kind == .ride, let last = step.stops.last {
                alerts.append(TripAlert(
                    stepIndex: index,
                    fireDate: stepStart.addingTimeInterval(step.duration - before),
                    stationName: last.name
                ))
            }
            stepStart = stepStart.addingTimeInterval(step.duration)
        }
        return alerts
    }

    /// The alerts as the system should hold them, given the ones it holds. `lead` is nil when the
    /// rider has alerts off.
    ///
    /// A correction never takes an alert away. One whose time has passed without being given is
    /// given at once, since a fix that shows the train further on than the clock had it is the
    /// moment the alert matters most. One already given is not given again.
    func alertPlan(holding held: [TripAlert], before lead: TimeInterval?, now: Date) -> TripAlertPlan {
        var plan = TripAlertPlan()
        guard let lead else {
            plan.cancel = held.map(\.stepIndex)
            return plan
        }
        let given = Set(held.filter { $0.fireDate <= now }.map(\.stepIndex))
        for alert in alerts(before: lead) {
            if alert.fireDate > now {
                plan.held.append(alert)
                plan.schedule.append(alert)
            } else if given.contains(alert.stepIndex) {
                plan.held.append(alert)
            } else {
                let due = TripAlert(stepIndex: alert.stepIndex, fireDate: now, stationName: alert.stationName)
                plan.held.append(due)
                plan.schedule.append(due)
            }
        }
        let wanted = Set(plan.held.map(\.stepIndex))
        for alert in held where !wanted.contains(alert.stepIndex) {
            // The ride is behind the rider. Put there by a fix at its last stop, with the alert
            // still to come, they are at the doors and have not been told. Their own Next needs
            // no telling, and nor does a fix further on: by then they are off the train.
            let justReached = anchor.basis == .located
                && anchor.stepIndex == alert.stepIndex + 1
                && anchor.elapsed == 0
            if justReached, alert.fireDate > now {
                plan.reached = TripAlert(stepIndex: alert.stepIndex, fireDate: now, stationName: alert.stationName)
            } else {
                plan.cancel.append(alert.stepIndex)
            }
        }
        return plan
    }

    // MARK: - Writing

    /// The rider says they are at this step. A ride is taken as boarded: Next onto "Board" is
    /// pressed with a foot in the door, and counting the boarding allowance again from there would
    /// put every alert on the ride that much late.
    mutating func confirm(stepIndex: Int, at date: Date) {
        guard steps.indices.contains(stepIndex) else { return }
        anchor = TripAnchor(
            stepIndex: stepIndex,
            elapsed: steps[stepIndex].boarding,
            date: date,
            basis: .confirmed
        )
    }

    /// The rider says the trip has run ahead of them and they are still at this earlier step.
    ///
    /// A walk or a change starts again. A ride does not: Back onto a ride is pressed by a rider
    /// the clock has already taken off the train, so they are near its end, and starting the ride
    /// over would count every stop again and put its alert a whole ride late. It is taken to be on
    /// its last hop, the latest place that is still on the train.
    mutating func goBack(to stepIndex: Int, at date: Date) {
        guard steps.indices.contains(stepIndex) else { return }
        let step = steps[stepIndex]
        let lastHop = step.stops.count >= 2 ? step.stops[step.stops.count - 2].offset : 0
        anchor = TripAnchor(
            stepIndex: stepIndex,
            elapsed: step.boarding + lastHop,
            date: date,
            basis: .confirmed
        )
    }

    /// Takes a fix as evidence. Returns whether it moved the anchor.
    @discardableResult
    mutating func observe(_ fix: TripFix, now: Date) -> Bool {
        guard fix.accuracy >= 0,
              now.timeIntervalSince(fix.date) <= Self.maximumFixAge,
              fix.date >= anchor.date,
              steps.indices.contains(anchor.stepIndex) else { return false }

        if fix.accuracy <= Self.accessFixAccuracy {
            // On the ground a tight fix is trusted outright, and may undo what only the clock
            // advanced: a rider still on the street is not on the train.
            for index in anchor.stepIndex..<steps.count where steps[index].kind == .access {
                guard let target = accessTarget(for: fix, step: index) else { continue }
                anchor = TripAnchor(stepIndex: target.stepIndex, elapsed: target.elapsed, date: fix.date, basis: .located)
                return true
            }
        }

        if fix.accuracy <= Self.rideFixAccuracy {
            for index in anchor.stepIndex..<steps.count where steps[index].kind == .ride {
                guard let stop = nearestStop(to: fix.point, in: steps[index]) else { continue }
                return observeStop(stop.index, distance: stop.distance, ofRide: index, fix: fix)
            }
        }

        // Under open sky and on none of the trip's paths: an access leg ends by being reached, not
        // by the clock, so it is held just short of its end while fixes this good keep arriving.
        if fix.accuracy <= Self.accessFixAccuracy, steps[anchor.stepIndex].kind == .access,
           steps[anchor.stepIndex].path.count >= 2 {
            let duration = steps[anchor.stepIndex].duration
            let run = anchor.elapsed + fix.date.timeIntervalSince(anchor.date)
            anchor = TripAnchor(
                stepIndex: anchor.stepIndex,
                elapsed: max(anchor.elapsed, min(run, duration - 1)),
                date: fix.date,
                basis: .located
            )
            return true
        }
        return false
    }

    // MARK: - Matching

    private func accessTarget(for fix: TripFix, step index: Int) -> (stepIndex: Int, elapsed: TimeInterval)? {
        let step = steps[index]
        guard let projection = TimelineGeometry.project(fix.point, onto: step.path),
              projection.distance <= Self.accessCorridor,
              let end = step.path.last else { return nil }
        if fix.point.distance(to: end) <= Self.accessArrivalRadius {
            return (min(index + 1, steps.count - 1), 0)
        }
        let fraction = projection.length > 0 ? projection.along / projection.length : 0
        return (index, fraction * step.duration)
    }

    /// The stop a fix is at, if it is clearly at one: nearer it than half the gap to either
    /// neighbour, so a fix between two stations names neither.
    private func nearestStop(to point: TimelinePoint, in step: TimelineStep) -> (index: Int, distance: Double)? {
        let located = step.stops.enumerated().compactMap { index, stop in
            stop.point.map { (index: index, distance: point.distance(to: $0)) }
        }
        guard let nearest = located.min(by: { $0.distance < $1.distance }),
              nearest.distance <= Self.rideStopRadius,
              let here = step.stops[nearest.index].point else { return nil }
        for neighbour in [nearest.index - 1, nearest.index + 1] where step.stops.indices.contains(neighbour) {
            guard let there = step.stops[neighbour].point else { continue }
            if nearest.distance >= here.distance(to: there) / 2 { return nil }
        }
        return nearest
    }

    private mutating func observeStop(_ stop: Int, distance: Double, ofRide index: Int, fix: TripFix) -> Bool {
        let step = steps[index]
        let date = fix.date
        let clock = clockPosition(at: date)

        if stop == 0 {
            // Reached from the street by a door the plan did not choose: the walk is over all the
            // same.
            if clock.stepIndex == index - 1, steps[clock.stepIndex].kind == .access,
               fix.accuracy <= Self.accessFixAccuracy, distance <= Self.stationArrivalRadius {
                anchor = TripAnchor(stepIndex: index, elapsed: 0, date: date, basis: .located)
                return true
            }
            // The boarding station. Being here says the train has not left, and nothing about
            // whether a change's walk to the platform is over, so it only matters once the clock
            // has the rider on this ride.
            guard clock.stepIndex == index else { return false }
            let heldSince = anchor.stepIndex == index ? (anchor.holdStartedAt ?? date) : date
            guard date.timeIntervalSince(heldSince) <= Self.boardingHoldLimit else { return false }
            // A departure the rider confirmed, or a later stop already seen, is not walked back.
            guard !departureKnown(ofRide: index) else { return false }
            anchor = TripAnchor(
                stepIndex: index,
                elapsed: min(clock.elapsed, step.boarding),
                date: date,
                basis: .located,
                holdStartedAt: heldSince
            )
            return true
        }

        let arrived = stop == step.stops.count - 1
        let target: (stepIndex: Int, elapsed: TimeInterval) = arrived
            ? (min(index + 1, steps.count - 1), 0)
            : (index, step.boarding + step.stops[stop].offset)
        // Never behind what was already observed or confirmed, and the same stop twice says nothing
        // new: the clock runs through the dwell.
        guard target.stepIndex > anchor.stepIndex
                || (target.stepIndex == anchor.stepIndex && target.elapsed > anchor.elapsed) else { return false }
        let lead = tripTime(stepIndex: target.stepIndex, elapsed: target.elapsed)
            - tripTime(stepIndex: clock.stepIndex, elapsed: clock.elapsed)
        guard fix.accuracy <= Self.satelliteFixAccuracy
                || (lead <= Self.ridePlausibilityAhead && lead >= -Self.ridePlausibilityBehind) else { return false }
        anchor = TripAnchor(stepIndex: target.stepIndex, elapsed: target.elapsed, date: date, basis: .located)
        return true
    }

    /// Whether the moment this ride's train left is known: the rider confirmed it, or a fix has
    /// since put them at a later stop.
    private func departureKnown(ofRide index: Int) -> Bool {
        anchor.stepIndex == index && anchor.elapsed >= steps[index].boarding && anchor.holdStartedAt == nil
    }

    // MARK: - Clock

    private func clockPosition(at now: Date) -> (stepIndex: Int, elapsed: TimeInterval, startedAt: Date) {
        guard !steps.isEmpty else { return (0, 0, now) }
        var index = min(max(anchor.stepIndex, 0), steps.count - 1)
        var elapsed = anchor.elapsed + max(0, now.timeIntervalSince(anchor.date))
        var startedAt = anchor.date.addingTimeInterval(-anchor.elapsed)
        while index < steps.count - 1, elapsed >= steps[index].duration {
            elapsed -= steps[index].duration
            startedAt = startedAt.addingTimeInterval(steps[index].duration)
            index += 1
        }
        return (index, min(elapsed, steps[index].duration), startedAt)
    }

    /// Seconds from the trip's start to a moment inside one of its steps, on the model's own clock.
    private func tripTime(stepIndex: Int, elapsed: TimeInterval) -> TimeInterval {
        steps.prefix(stepIndex).reduce(0) { $0 + $1.duration } + elapsed
    }

    private func stopsPassed(in step: TimelineStep, elapsed: TimeInterval) -> Int {
        guard step.kind == .ride else { return 0 }
        // `boarding + offset` on the stop's side, the sum an anchor at a stop is written with.
        // Taking the boarding time off `elapsed` instead does not always give the offset back
        // (180 + 88.7 - 180 is a hair under 88.7), and a rider just located at a stop would read
        // as one stop short of it, and then as estimated.
        return step.stops.lastIndex { step.boarding + $0.offset <= elapsed } ?? 0
    }
}
