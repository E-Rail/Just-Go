import Foundation

struct StationIndoorMap: Codable, Equatable {
    let schemaVersion: Int?
    let stationID: String
    let version: String
    let source: String
    let confidence: DataConfidence
    let coverageMode: IndoorMapCoverageMode?
    let provenance: IndoorMapProvenance?
    let levels: [IndoorLevel]
    let nodes: [IndoorNode]
    let edges: [IndoorEdge]
    let landmarks: [IndoorLandmark]
    let mapImageCalibration: MapImageCalibration?
    let boardingZoneHints: [IndoorBoardingZoneHint]?
    let lineCoverageGaps: [IndoorLineCoverageGap]?

    var effectiveSchemaVersion: Int { schemaVersion ?? 1 }
    var effectiveCoverageMode: IndoorMapCoverageMode {
        coverageMode ?? (edges.isEmpty ? .platformCheckpoints : .transferPaths)
    }
    var resolvedBoardingZoneHints: [IndoorBoardingZoneHint] { boardingZoneHints ?? [] }
    var resolvedLineCoverageGaps: [IndoorLineCoverageGap] { lineCoverageGaps ?? [] }
}

enum IndoorMapCoverageMode: String, Codable {
    case platformCheckpoints
    case transferPaths
}

enum IndoorMapReviewStatus: String, Codable {
    case draft
    case diagramReviewed
    case onSiteVerified
}

enum IndoorAssetUsageStatus: String, Codable {
    case approvedEmbedded
    case approvedRemote
    case metadataOnly
    case blocked
    case reviewRequired
}

enum IndoorLineCoverageGapReason: String, Codable {
    case sourceDoesNotDepictLine
}

struct IndoorLineCoverageGap: Codable, Equatable {
    let lineID: String
    let reason: IndoorLineCoverageGapReason
    let note: String
}

struct IndoorMapProvenance: Codable, Equatable {
    let sourceURL: String
    let sourceContentSHA256: String
    let retrievedAt: String?
    let authoredAt: String?
    let reviewedAt: String?
    let reviewStatus: IndoorMapReviewStatus
    let assetUsageStatus: IndoorAssetUsageStatus
    let notes: [String]
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
    let lineID: String?
    let platformID: String?
    let arrivalFromStationIDs: [String]?
    let departureTowardStationIDs: [String]?
    let recognitionAliases: [String]?

    var resolvedArrivalFromStationIDs: [String] { arrivalFromStationIDs ?? [] }
    var resolvedDepartureTowardStationIDs: [String] { departureTowardStationIDs ?? [] }
    var resolvedRecognitionAliases: [String] { recognitionAliases ?? [] }
}

enum IndoorTraversalKind: String, Codable {
    case walkway
    case stairs
    case escalator
    case elevator
    case gate
}

enum IndoorInstructionAction: String, Codable {
    case continueStraight
    case turnLeft
    case turnRight
    case followSigns
    case takeStairs
    case takeEscalator
    case takeElevator
}

struct IndoorDirectedInstruction: Codable, Equatable {
    let action: IndoorInstructionAction
    let signText: String?
    let landmarkNodeID: String?
}

struct IndoorEdge: Identifiable, Codable, Equatable {
    let id: String
    let fromNodeID: String
    let toNodeID: String
    let distanceMeters: Double
    let typicalSeconds: TimeInterval
    let isStepFree: Bool
    let isBidirectional: Bool
    let traversalKind: IndoorTraversalKind?
    let shape: [IndoorCoordinate]?
    let forwardInstruction: IndoorDirectedInstruction?
    let reverseInstruction: IndoorDirectedInstruction?

    var resolvedShape: [IndoorCoordinate] { shape ?? [] }
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

    enum PlatformRole {
        case arrival
        case departure
    }

    func platformNodes(for leg: TransitLegContext, role: PlatformRole) -> [IndoorNode] {
        let lineMatches = nodes.filter { $0.kind == .platform && $0.lineID == leg.lineID }
        guard !lineMatches.isEmpty else {
            return nodes(kind: .platform, matchingLineName: leg.lineName)
        }

        let directionStationID: String? = switch role {
        case .arrival: rawNetworkStationID(leg.arrivalPreviousStationID)
        case .departure: rawNetworkStationID(leg.directionNextStationID)
        }
        guard let directionStationID else { return lineMatches }

        let directed = lineMatches.filter { node in
            switch role {
            case .arrival: node.resolvedArrivalFromStationIDs.contains(directionStationID)
            case .departure: node.resolvedDepartureTowardStationIDs.contains(directionStationID)
            }
        }
        return directed.isEmpty ? lineMatches.filter {
            $0.resolvedArrivalFromStationIDs.isEmpty && $0.resolvedDepartureTowardStationIDs.isEmpty
        } : directed
    }

    private func rawNetworkStationID(_ value: String?) -> String? {
        guard let value else { return nil }
        let prefix = "network-"
        guard value.hasPrefix(prefix),
              let citySeparator = value.dropFirst(prefix.count).firstIndex(of: "-") else { return value }
        return String(value[value.index(after: citySeparator)...])
    }

    struct PathResult {
        let nodeIDs: [String]
        let edgeIDs: [String]
        let meters: Double
        let minutes: Double
        let startNodeID: String
        let endNodeID: String
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

        var bestCost: [String: Double] = [:]
        var previous: [String: (node: String, edge: IndoorEdge)] = [:]
        var visited: Set<String> = []
        var frontier: [(node: String, cost: Double)] = from.map { ($0, 0) }
        for id in from { bestCost[id] = 0 }

        while !frontier.isEmpty {
            frontier.sort { $0.cost < $1.cost }
            let current = frontier.removeFirst()
            guard !visited.contains(current.node) else { continue }
            visited.insert(current.node)

            if targets.contains(current.node) {
                var path = [current.node]
                var edgeIDs: [String] = []
                var meters = 0.0
                var seconds = 0.0
                var cursor = current.node
                while let step = previous[cursor] {
                    meters += step.edge.distanceMeters
                    seconds += step.edge.typicalSeconds
                    edgeIDs.append(step.edge.id)
                    path.append(step.node)
                    cursor = step.node
                }
                let nodeIDs = Array(path.reversed())
                return PathResult(
                    nodeIDs: nodeIDs,
                    edgeIDs: edgeIDs.reversed(),
                    meters: meters,
                    minutes: seconds / 60,
                    startNodeID: nodeIDs.first!,
                    endNodeID: nodeIDs.last!
                )
            }

            for (neighbor, edge) in adjacency[current.node] ?? [] where !visited.contains(neighbor) {
                let candidateCost = current.cost + edge.typicalSeconds
                if candidateCost < (bestCost[neighbor] ?? .infinity) {
                    bestCost[neighbor] = candidateCost
                    previous[neighbor] = (current.node, edge)
                    frontier.append((neighbor, candidateCost))
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
    var routeEdgeIDs: [String] = []
    let walkingMeters: Double?
    let walkingMinutes: Double?
    let stepFreeAlternativeNodeIDs: [String]
    let notes: [String]
    let confidence: DataConfidence
}

enum IndoorBoardingZone: String, Codable {
    case front
    case middle
    case rear

    var localizedLabel: String {
        switch self {
        case .front:
            AppLocalization.text(english: "Front of train", simplified: "列车前部", traditional: "列車前部")
        case .middle:
            AppLocalization.text(english: "Middle of train", simplified: "列车中部", traditional: "列車中部")
        case .rear:
            AppLocalization.text(english: "Rear of train", simplified: "列车后部", traditional: "列車後部")
        }
    }
}

struct IndoorBoardingZoneHint: Codable, Equatable {
    let incomingLineID: String
    let arrivalFromStationID: String?
    let transferToLineID: String
    let zone: IndoorBoardingZone
    let accessible: Bool?
    let evidenceNodeID: String
    let confidence: DataConfidence
}

struct IndoorBoardingZoneGuidance: Codable, Equatable {
    let stationID: String
    let incomingLineID: String
    let transferToLineID: String
    let zone: IndoorBoardingZone
    let accessible: Bool?
    let evidenceNodeID: String
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
