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
    /// Station coordinate for `.transfer` steps, used to render a 3D map preview.
    /// `CodableCoordinate` (not `CLLocationCoordinate2D`) keeps `Equatable` synthesis working —
    /// matches the same raw-then-computed-coordinate pattern used by `Station`/`RouteStationStop`.
    var transferCoordinate: CodableCoordinate? = nil
    /// Apple's real, already-computed walking-route polyline for `.walkToStation`/
    /// `.walkToDestination` steps (the same data already stored on `RouteSegment.polylineCoordinates`).
    var walkingPathCoordinates: [CodableCoordinate] = []

    var transferCLCoordinate: CLLocationCoordinate2D? {
        transferCoordinate.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
    }

    var walkingPathCLCoordinates: [CLLocationCoordinate2D] {
        walkingPathCoordinates.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
    }

    var title: String {
        switch kind {
        case .walkToStation:
            let station = toStationName ?? AppLocalization.text(english: "the station", simplified: "车站", traditional: "車站")
            return AppLocalization.text(
                english: "Walk to \(station)",
                simplified: "步行至\(station)",
                traditional: "步行至\(station)"
            )
        case .ride:
            let line = lineName ?? AppLocalization.text(english: "the train", simplified: "列车", traditional: "列車")
            return AppLocalization.text(english: "Board \(line)", simplified: "乘坐\(line)", traditional: "乘坐\(line)")
        case .transfer:
            let line = lineName ?? AppLocalization.text(english: "the next line", simplified: "下一条线路", traditional: "下一條路線")
            return AppLocalization.text(english: "Transfer to \(line)", simplified: "换乘\(line)", traditional: "換乘\(line)")
        case .walkToDestination:
            let place = toStationName ?? AppLocalization.text(english: "your destination", simplified: "目的地", traditional: "目的地")
            return AppLocalization.text(english: "Walk to \(place)", simplified: "步行至\(place)", traditional: "步行至\(place)")
        case .arrive:
            return AppLocalization.text(english: "You have arrived", simplified: "您已到达", traditional: "您已抵達")
        }
    }

    var detail: String? {
        switch kind {
        case .walkToStation, .walkToDestination:
            guard walkingDistance >= 1 else { return nil }
            return AppLocalization.distance(walkingDistance)
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
