import Foundation

struct StationIndoorMap: Codable, Equatable {
    let stationID: String
    let version: String
    let source: String
    let confidence: DataConfidence
    let levels: [IndoorLevel]
    let nodes: [IndoorNode]
    let edges: [IndoorEdge]
    let landmarks: [IndoorLandmark]
    let mapImageCalibration: MapImageCalibration?
}

struct IndoorLevel: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    let ordinal: Int
}

struct IndoorNode: Identifiable, Codable, Equatable {
    enum Kind: String, Codable {
        case platform
        case exit
        case gate
        case elevator
        case escalator
        case stairs
        case corridor
        case concourse
    }

    let id: String
    let kind: Kind
    let levelID: String
    let title: String
    let coordinate: IndoorCoordinate
    let geoCoordinate: CodableCoordinate?
    let isStepFree: Bool
}

struct IndoorEdge: Identifiable, Codable, Equatable {
    let id: String
    let fromNodeID: String
    let toNodeID: String
    let distanceMeters: Double
    let typicalSeconds: TimeInterval
    let isStepFree: Bool
    let isBidirectional: Bool
}

struct IndoorLandmark: Identifiable, Codable, Equatable {
    let id: String
    let title: String
    let levelID: String
    let coordinate: IndoorCoordinate
}

/// For stations traced from a bundled official isometric diagram (the only indoor-layout
/// source this app has), `x`/`y` are fractional 0...1 position within that diagram image
/// — not meters or geo-calibrated — so a node renders at the same spot on the image
/// regardless of the size the image is displayed at. `z` is unused for this source (the
/// diagrams draw all levels in one flattened isometric image) and is reserved for a future
/// source that separates levels spatially.
struct IndoorCoordinate: Codable, Equatable {
    let x: Double
    let y: Double
    let z: Double
}

extension StationIndoorMap {
    /// Nodes of the given kind whose title mentions `lineName` — how platform nodes are
    /// resolved from a route segment's line name (e.g. "2号线", "Line 2").
    func nodes(kind: IndoorNode.Kind, matchingLineName lineName: String) -> [IndoorNode] {
        nodes.filter { $0.kind == kind && $0.title.localizedCaseInsensitiveContains(lineName) }
    }

    struct PathResult {
        let nodeIDs: [String]
        let meters: Double
        let minutes: Double
    }

    /// Dijkstra shortest path from any node in `from` to any node in `to`, optionally
    /// restricted to step-free edges. Graphs are small (traced by hand from a single
    /// station diagram, ~10-25 nodes) so a plain array frontier outperforms the bookkeeping
    /// a heap would need. Returns nil when no path exists under the given constraint.
    func shortestPath(from: [String], to: [String], stepFreeOnly: Bool) -> PathResult? {
        guard !from.isEmpty, !to.isEmpty else { return nil }
        let targets = Set(to)

        var adjacency: [String: [(neighbor: String, edge: IndoorEdge)]] = [:]
        for edge in edges where !stepFreeOnly || edge.isStepFree {
            adjacency[edge.fromNodeID, default: []].append((edge.toNodeID, edge))
            if edge.isBidirectional {
                adjacency[edge.toNodeID, default: []].append((edge.fromNodeID, edge))
            }
        }

        var bestDistance: [String: Double] = [:]
        var previous: [String: (node: String, edge: IndoorEdge)] = [:]
        var visited: Set<String> = []
        var frontier: [(node: String, distance: Double)] = from.map { ($0, 0) }
        for id in from { bestDistance[id] = 0 }

        while !frontier.isEmpty {
            frontier.sort { $0.distance < $1.distance }
            let current = frontier.removeFirst()
            guard !visited.contains(current.node) else { continue }
            visited.insert(current.node)

            if targets.contains(current.node) {
                var path = [current.node]
                var meters = 0.0
                var seconds = 0.0
                var cursor = current.node
                while let step = previous[cursor] {
                    meters += step.edge.distanceMeters
                    seconds += step.edge.typicalSeconds
                    path.append(step.node)
                    cursor = step.node
                }
                return PathResult(nodeIDs: path.reversed(), meters: meters, minutes: seconds / 60)
            }

            for (neighbor, edge) in adjacency[current.node] ?? [] where !visited.contains(neighbor) {
                let candidateDistance = current.distance + edge.distanceMeters
                if candidateDistance < (bestDistance[neighbor] ?? .infinity) {
                    bestDistance[neighbor] = candidateDistance
                    previous[neighbor] = (current.node, edge)
                    frontier.append((neighbor, candidateDistance))
                }
            }
        }
        return nil
    }
}

struct MapImageCalibration: Codable, Equatable {
    let assetURL: String
    let levelID: String
    let origin: IndoorCoordinate
    let scaleMetersPerPoint: Double
}

struct PlatformStopProfile: Codable, Equatable {
    let stationID: String
    let lineName: String
    let directionText: String?
    let platformID: String
    let carCount: Int
    let doorsPerCar: Int
    let stoppingOffsetMeters: Double
    let doorPositions: [PlatformDoorPosition]
    let accessibleBoardingZones: [String]
    let confidence: DataConfidence
}

struct PlatformDoorPosition: Identifiable, Codable, Equatable {
    let id: String
    let carNumber: Int
    let doorNumber: Int
    let nodeID: String?
    let offsetMeters: Double
}

struct TransferPathHint: Codable, Equatable {
    let stationID: String
    let fromLineName: String?
    let fromPlatformID: String?
    let toLineName: String?
    let toPlatformID: String?
    let routeNodeIDs: [String]
    let walkingMeters: Double?
    let walkingMinutes: Double?
    let stepFreeAlternativeNodeIDs: [String]
    let notes: [String]
    let confidence: DataConfidence
}

enum DoorGuidanceTarget: String, Codable {
    case transfer
    case exit
    case elevator
    case stepFreeExit
}

struct DoorGuidance: Codable, Equatable {
    let stationID: String
    let lineName: String?
    let directionText: String?
    let target: DoorGuidanceTarget
    let recommendedCars: [Int]
    let recommendedDoorText: String?
    let notes: [String]
    let confidence: DataConfidence
}
