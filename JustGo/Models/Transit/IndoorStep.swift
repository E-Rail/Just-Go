import Foundation

/// One discrete, actionable instruction in an indoor turn-by-turn walkthrough — the
/// step-by-step equivalent of `TripStep`, but generated from a `StationIndoorMap`'s traced
/// node graph instead of a real GPS route. See `IndoorStep.build`.
enum IndoorStepKind: Equatable {
    case walk
    case turnLeft
    case turnRight
    case stairs
    case elevator
    case arrivePlatform
    case arriveExit

    var icon: String {
        switch self {
        case .walk: "arrow.up"
        case .turnLeft: "arrow.turn.up.left"
        case .turnRight: "arrow.turn.up.right"
        case .stairs: "figure.stairs"
        case .elevator: "arrow.up.arrow.down.circle.fill"
        case .arrivePlatform: "tram.fill"
        case .arriveExit: "arrow.up.forward.circle.fill"
        }
    }
}

struct IndoorStep: Identifiable, Equatable {
    let id: Int
    let kind: IndoorStepKind
    let title: String
    let detail: String?
    let legMeters: Double
    /// Indices into the resolved path's node-ID array this step covers — lets a renderer
    /// highlight just this step's segment on the station diagram while dimming the rest
    /// (turn/elevator/stairs events are a single point: `fromNodeIndex == throughNodeIndex`).
    let fromNodeIndex: Int
    let throughNodeIndex: Int
}

private enum TurnBucket {
    case straight
    case left
    case right
}

extension IndoorStep {
    /// Builds an ordered turn-by-turn walkthrough from a Dijkstra path's node sequence.
    ///
    /// Distances come from `map.edges` between consecutive nodes; turn direction is bucketed
    /// (straight / left / right — never a specific angle) from the cross product of the
    /// incoming/outgoing vectors in the diagram's fractional coordinates. Left/right holds up
    /// even though the source diagram is isometric, not a true top-down plan — an axonometric
    /// projection doesn't mirror-flip — but an exact degree would be false precision on data
    /// traced by hand from a single image, so only coarse buckets are ever produced.
    ///
    /// A node whose `kind` is `.elevator` or `.stairs` always becomes its own dedicated step
    /// regardless of the turn angle there, since "take the elevator" matters more than the
    /// incidental turn direction at that point. Consecutive straight-walking hops collapse
    /// into one combined step; the final hop's distance folds into the arrival step rather
    /// than getting its own "continue" card first.
    static func build(nodeIDs: [String], map: StationIndoorMap, destinationLineName: String?) -> [IndoorStep] {
        guard nodeIDs.count > 1 else { return [] }
        let nodesByID = Dictionary(uniqueKeysWithValues: map.nodes.map { ($0.id, $0) })

        var edgeByPair: [String: IndoorEdge] = [:]
        for edge in map.edges {
            edgeByPair["\(edge.fromNodeID)->\(edge.toNodeID)"] = edge
            if edge.isBidirectional {
                edgeByPair["\(edge.toNodeID)->\(edge.fromNodeID)"] = edge
            }
        }

        var steps: [IndoorStep] = []
        var pendingMeters = 0.0
        var segmentStartIndex = 0
        var nextID = 0

        func flushWalk(throughIndex: Int) {
            defer { pendingMeters = 0; segmentStartIndex = throughIndex }
            guard pendingMeters > 0.5 else { return }
            steps.append(IndoorStep(
                id: nextID,
                kind: .walk,
                title: AppLocalization.text(english: "Continue straight", simplified: "直行", traditional: "直行"),
                detail: AppLocalization.distance(pendingMeters),
                legMeters: pendingMeters,
                fromNodeIndex: segmentStartIndex,
                throughNodeIndex: throughIndex
            ))
            nextID += 1
        }

        for index in 1..<nodeIDs.count {
            let fromID = nodeIDs[index - 1]
            let toID = nodeIDs[index]
            guard let toNode = nodesByID[toID],
                  let edge = edgeByPair["\(fromID)->\(toID)"] else { continue }
            let isLast = index == nodeIDs.count - 1

            if isLast {
                pendingMeters += edge.distanceMeters
                let detail = pendingMeters > 0.5 ? AppLocalization.distance(pendingMeters) : nil
                steps.append(arrivalStep(
                    id: nextID, node: toNode, detail: detail, destinationLineName: destinationLineName,
                    fromNodeIndex: segmentStartIndex, throughNodeIndex: index
                ))
                continue
            }

            if toNode.kind == .elevator || toNode.kind == .stairs {
                flushWalk(throughIndex: index - 1)
                steps.append(IndoorStep(
                    id: nextID,
                    kind: toNode.kind == .elevator ? .elevator : .stairs,
                    title: toNode.kind == .elevator
                        ? AppLocalization.text(english: "Take the elevator", simplified: "乘坐电梯", traditional: "搭乘電梯")
                        : AppLocalization.text(english: "Take the stairs", simplified: "走楼梯", traditional: "走樓梯"),
                    detail: nil,
                    legMeters: edge.distanceMeters,
                    fromNodeIndex: index - 1,
                    throughNodeIndex: index
                ))
                nextID += 1
                segmentStartIndex = index
                continue
            }

            pendingMeters += edge.distanceMeters

            // Interior walking node: bucket the turn using the segment before and after it.
            let prevID = nodeIDs[index - 1]
            let nextNodeID = nodeIDs[index + 1]
            guard let prevNode = nodesByID[prevID], let nextNode = nodesByID[nextNodeID] else { continue }
            let turn = turnBucket(prev: prevNode.coordinate, cur: toNode.coordinate, next: nextNode.coordinate)
            switch turn {
            case .straight:
                continue
            case .left, .right:
                flushWalk(throughIndex: index)
                steps.append(IndoorStep(
                    id: nextID,
                    kind: turn == .left ? .turnLeft : .turnRight,
                    title: turn == .left
                        ? AppLocalization.text(english: "Turn left", simplified: "向左转", traditional: "向左轉")
                        : AppLocalization.text(english: "Turn right", simplified: "向右转", traditional: "向右轉"),
                    detail: nil,
                    legMeters: 0,
                    fromNodeIndex: index,
                    throughNodeIndex: index
                ))
                nextID += 1
                segmentStartIndex = index
            }
        }

        return steps
    }

    private static func arrivalStep(
        id: Int, node: IndoorNode, detail: String?, destinationLineName: String?,
        fromNodeIndex: Int, throughNodeIndex: Int
    ) -> IndoorStep {
        switch node.kind {
        case .exit, .gate:
            let letter = exitLabel(from: node.title)
            return IndoorStep(
                id: id,
                kind: .arriveExit,
                title: AppLocalization.text(
                    english: "Head to Exit \(letter)",
                    simplified: "前往\(letter)口",
                    traditional: "前往\(letter)口"
                ),
                detail: detail,
                legMeters: 0,
                fromNodeIndex: fromNodeIndex,
                throughNodeIndex: throughNodeIndex
            )
        default:
            let line = destinationLineName ?? AppLocalization.text(english: "the platform", simplified: "站台", traditional: "月台")
            return IndoorStep(
                id: id,
                kind: .arrivePlatform,
                title: AppLocalization.text(
                    english: "Arrive at the \(line) platform",
                    simplified: "到达\(line)站台",
                    traditional: "到達\(line)月台"
                ),
                detail: detail,
                legMeters: 0,
                fromNodeIndex: fromNodeIndex,
                throughNodeIndex: throughNodeIndex
            )
        }
    }

    /// Pulls just the exit letter/number out of a traced node title (e.g. "E口" → "E",
    /// "A口（北京北站方向）" → "A") so an English UI shows "Head to Exit A" rather than mixing
    /// in untranslated Chinese — the traced titles were only ever authored for map-matching,
    /// not display.
    private static func exitLabel(from title: String) -> String {
        if let range = title.range(of: "^[A-Za-z0-9]{1,3}(?=口)", options: .regularExpression) {
            return String(title[range]).uppercased()
        }
        return title
    }

    private static func turnBucket(prev: IndoorCoordinate, cur: IndoorCoordinate, next: IndoorCoordinate) -> TurnBucket {
        let inX = cur.x - prev.x
        let inY = cur.y - prev.y
        let outX = next.x - cur.x
        let outY = next.y - cur.y
        let cross = inX * outY - inY * outX
        let dot = inX * outX + inY * outY
        guard cross != 0 || dot != 0 else { return .straight }
        let angleDegrees = atan2(cross, dot) * 180 / .pi
        if abs(angleDegrees) < 20 { return .straight }
        return angleDegrees > 0 ? .right : .left
    }
}
