import Foundation
import CoreLocation

/// A single step in the Live "Go" in-station companion.
enum LiveStepKind: Equatable {
    case walkToStation
    case ride
    case transfer
    case walkToDestination
    case arrive
}

/// One ordered step of a guided trip, derived purely from `Route.segments`.
struct TripStep: Identifiable, Equatable {
    let id: Int
    let kind: LiveStepKind
    let lineName: String?
    let lineColorHex: String?
    let fromStationName: String?
    let toStationName: String?
    let stopCount: Int
    let walkingDistance: Double
    /// Estimated duration of this step (from the underlying route segment). Used to schedule an
    /// estimated "get off" alert when a ride step starts. There is no live train-position feed.
    var duration: TimeInterval = 0
    /// Recommended exit/entrance at the step's end station, when known (best-available).
    var exitHint: String? = nil
    /// Station coordinate for `.transfer` steps, used to frame the outdoor map and any
    /// separately verified indoor guidance.
    /// `CodableCoordinate` (not `CLLocationCoordinate2D`) keeps `Equatable` synthesis working.
    /// Matches the same raw-then-computed-coordinate pattern used by `Station`/`RouteStationStop`.
    var transferCoordinate: CodableCoordinate? = nil
    /// Apple's real, already-computed walking-route polyline for `.walkToStation`/
    /// `.walkToDestination` steps (the same data already stored on `RouteSegment.polylineCoordinates`).
    var walkingPathCoordinates: [CodableCoordinate] = []
    /// Index of the `Route.segments` entry this step came from (nil for the synthetic
    /// `.arrive` step): lets the live map frame the step's real geometry.
    var segmentIndex: Int? = nil
    var transferContext: TransferContext? = nil
    /// How the rider covers this access leg. The step *kind* stays `.walkToStation` /
    /// `.walkToDestination` because everything structural about the step is the same. It is the
    /// first or last mile, it has a drawn path, it frames the same way. Only the verb changes,
    /// and telling someone to "walk" a 9 km drive is exactly the kind of confident wrong sentence
    /// this app exists not to produce.
    var accessMode: AccessLegMode = .walking

    var transferCLCoordinate: CLLocationCoordinate2D? {
        transferCoordinate.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
    }

    var walkingPathCLCoordinates: [CLLocationCoordinate2D] {
        walkingPathCoordinates.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
    }

    var title: String {
        switch kind {
        case .walkToStation:
            // The entrance when the plan resolved one. This is a rider standing on the street
            // looking for a way in, and "walk to 北京站" points at a building with eight of them.
            let target = exitHint
                ?? toStationName
                ?? AppLocalization.text(english: "the station", simplified: "车站", traditional: "車站")
            switch accessMode {
            case .walking:
                return AppLocalization.text(
                    english: "Walk to \(target)",
                    simplified: "步行至\(target)",
                    traditional: "步行至\(target)"
                )
            case .cycling:
                return AppLocalization.text(
                    english: "Cycle to \(target)",
                    simplified: "骑行至\(target)",
                    traditional: "騎行至\(target)"
                )
            case .driving:
                return AppLocalization.text(
                    english: "Drive to \(target)",
                    simplified: "驾车至\(target)",
                    traditional: "駕車至\(target)"
                )
            }
        case .ride:
            let line = lineName ?? AppLocalization.text(english: "the train", simplified: "列车", traditional: "列車")
            return AppLocalization.text(english: "Board \(line)", simplified: "乘坐\(line)", traditional: "乘坐\(line)")
        case .transfer:
            // An out-of-station interchange has no outgoing line to name — it is a walk between two
            // stations — so it names the station instead of falling through to "the next line",
            // which tells a rider standing at the gates nothing they can act on.
            guard let lineName else {
                if let station = toStationName, station != fromStationName {
                    return AppLocalization.text(
                        english: "Walk to \(station) to change",
                        simplified: "出站步行至\(station)换乘",
                        traditional: "出站步行至\(station)換乘"
                    )
                }
                return AppLocalization.text(english: "Change here", simplified: "在此换乘", traditional: "在此換乘")
            }
            return AppLocalization.text(
                english: "Transfer to \(lineName)",
                simplified: "换乘\(lineName)",
                traditional: "換乘\(lineName)"
            )
        case .walkToDestination:
            let place = toStationName ?? AppLocalization.text(english: "your destination", simplified: "目的地", traditional: "目的地")
            switch accessMode {
            case .walking:
                return AppLocalization.text(english: "Walk to \(place)", simplified: "步行至\(place)", traditional: "步行至\(place)")
            case .cycling:
                return AppLocalization.text(english: "Cycle to \(place)", simplified: "骑行至\(place)", traditional: "騎行至\(place)")
            case .driving:
                return AppLocalization.text(english: "Drive to \(place)", simplified: "驾车至\(place)", traditional: "駕車至\(place)")
            }
        case .arrive:
            return AppLocalization.text(english: "You have arrived", simplified: "您已到达", traditional: "您已抵達")
        }
    }

    var detail: String? {
        switch kind {
        case .walkToStation, .walkToDestination:
            // Whatever the title did not say. On the way in the title names the door, so the
            // station belongs here; on the way out the title names the destination, so the door
            // does. Either way the rider gets both facts without either line repeating the other.
            let context = kind == .walkToStation ? (exitHint == nil ? nil : toStationName) : exitHint
            let pieces = [context, walkingDistance >= 1 ? AppLocalization.distance(walkingDistance) : nil]
                .compactMap { $0 }
            return pieces.isEmpty ? nil : pieces.joined(separator: " · ")
        case .ride:
            let stops = AppLocalization.stops(stopCount)
            if let to = toStationName {
                return AppLocalization.text(
                    english: "Ride \(stops), get off at \(to)",
                    simplified: "乘坐\(stops)，在\(to)下车",
                    traditional: "乘坐\(stops)，在\(to)下車"
                )
            }
            return AppLocalization.text(english: "Ride \(stops)", simplified: "乘坐\(stops)", traditional: "乘坐\(stops)")
        case .transfer:
            guard let station = fromStationName else { return nil }
            return AppLocalization.text(english: "at \(station)", simplified: "在\(station)", traditional: "在\(station)")
        case .arrive:
            return toStationName
        }
    }

    /// Stops remaining once aboard this ride step (used for the progress readout).
    var rideStopsRemainingText: String? {
        guard kind == .ride, stopCount > 0 else { return nil }
        return AppLocalization.stopsLeft(stopCount)
    }

    var accessibilityLabel: String {
        [title, detail].compactMap { $0 }.joined(separator: ", ")
    }
}

/// An ordered, render-ready plan for the Live "Go" companion.
struct LiveTripPlan: Equatable {
    let steps: [TripStep]
    let origin: String
    let destination: String

    var isEmpty: Bool { steps.isEmpty }
    var count: Int { steps.count }
}
