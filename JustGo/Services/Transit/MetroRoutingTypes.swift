import CoreLocation
import MapKit

struct MetroRouteContext {
    /// Every pack the trip can use, not the single closest one. A trip from Foshan's metro to
    /// Guangzhou's crosses two packs and calls at an intercity corridor carried by both; picking
    /// one network made that trip unplannable rather than merely badly planned.
    let networks: [MetroNetwork]
    let originStations: [MetroStationCandidate]
    let destinationStations: [MetroStationCandidate]
}

struct MetroRoutingGraph {
    let stationsByID: [String: MetroStation]
    let linesByID: [String: MetroLine]
    let adjacency: [String: [MetroGraphEdge]]
    let edgeGeometries: [MetroGraphEdgeKey: [CodableCoordinate]]
    /// Which pack each station came from. The graph spans several, and every rider-facing station
    /// ID is `network-<city>-<station>` — so the city is a property of the station now, not of the
    /// search.
    let cityIDByStationID: [String: String]

    func cityID(for stationID: String) -> String {
        cityIDByStationID[stationID] ?? ""
    }

    /// The `network-<city>-<station>` identifier the rest of the app indexes stations by.
    func qualifiedID(for stationID: String) -> String {
        "network-\(cityID(for: stationID))-\(stationID)"
    }
}

struct MetroStationCandidate {
    let station: MetroStation
    let distance: Double
}

struct MetroGraphEdge {
    let fromStationID: String
    let toStationID: String
    let lineID: String
    let distance: Double
    /// nil for a ride between two stops. Set to the declared link between two stations riders
    /// treat as one interchange, which is walked rather than ridden and belongs to no line.
    var interchange: MetroInterchange? = nil

    var reversed: MetroGraphEdge {
        MetroGraphEdge(
            fromStationID: toStationID,
            toStationID: fromStationID,
            lineID: lineID,
            distance: distance,
            interchange: interchange
        )
    }

    var key: MetroGraphEdgeKey {
        MetroGraphEdgeKey(fromStationID: fromStationID, toStationID: toStationID, lineID: lineID)
    }
}

struct MetroGraphEdgeKey: Hashable {
    let fromStationID: String
    let toStationID: String
    let lineID: String
}

/// The synthetic line an interchange link rides on. Interchange links belong to no real line, and
/// the route assembly chunks by line — giving them their own identifier is what keeps them from
/// being folded into the ride on either side of them.
let metroInterchangeLineID = "__interchange__"


struct MetroPath {
    let origin: MetroStationCandidate
    let destination: MetroStationCandidate
    let edges: [MetroGraphEdge]
}

struct MetroSearchState: Hashable {
    let stationID: String
    let lineID: String?
}

struct MetroPreviousStep {
    let state: MetroSearchState
    let edge: MetroGraphEdge
}

enum MetroSearchPreference {
    case fastest
    case fewestTransfers
    case leastWalking

    var transferPenalty: Double {
        self == .fewestTransfers ? 1_200 : 300
    }

    var walkingWeight: Double {
        self == .leastWalking ? 3 : 1
    }

    var strategy: RouteStrategy {
        switch self {
        case .fastest: return .fastest
        case .fewestTransfers: return .fewestTransfers
        case .leastWalking: return .leastWalking
        }
    }
}

struct MetroQueueItem {
    let state: MetroSearchState
    let cost: Double
}

struct MetroMinHeap {
    private var values: [MetroQueueItem] = []

    mutating func insert(_ value: MetroQueueItem) {
        values.append(value)
        var index = values.count - 1
        while index > 0 {
            let parent = (index - 1) / 2
            guard values[index].cost < values[parent].cost else { break }
            values.swapAt(index, parent)
            index = parent
        }
    }

    mutating func removeMin() -> MetroQueueItem? {
        guard !values.isEmpty else { return nil }
        if values.count == 1 { return values.removeLast() }
        let result = values[0]
        values[0] = values.removeLast()
        var index = 0
        while true {
            let left = index * 2 + 1
            let right = left + 1
            var smallest = index
            if left < values.count && values[left].cost < values[smallest].cost { smallest = left }
            if right < values.count && values[right].cost < values[smallest].cost { smallest = right }
            guard smallest != index else { break }
            values.swapAt(index, smallest)
            index = smallest
        }
        return result
    }
}

extension MetroStation {
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

extension MetroCoordinate {
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

extension Array {
    var adjacentPairs: [(Element, Element)] {
        zip(self, dropFirst()).map { ($0, $1) }
    }

    func chunked(where belongsTogether: (Element, Element) -> Bool) -> [[Element]] {
        guard let first else { return [] }
        var chunks = [[first]]
        for item in dropFirst() {
            if let previous = chunks.last?.last, belongsTogether(previous, item) {
                chunks[chunks.count - 1].append(item)
            } else {
                chunks.append([item])
            }
        }
        return chunks
    }
}

extension Array where Element: Equatable {
    var consecutiveUnique: [Element] {
        reduce(into: []) { result, item in
            if result.last != item { result.append(item) }
        }
    }
}

extension MKPolyline {
    var routeCoordinates: [CLLocationCoordinate2D] {
        var values = Array(repeating: kCLLocationCoordinate2DInvalid, count: pointCount)
        getCoordinates(&values, range: NSRange(location: 0, length: pointCount))
        return values
    }
}
