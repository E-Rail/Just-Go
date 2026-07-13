import Foundation

/// One discrete, actionable instruction in an indoor turn-by-turn walkthrough — the
/// step-by-step equivalent of `TripStep`, but generated from a `StationIndoorMap`'s traced
/// node graph instead of a real GPS route. See `IndoorStep.build`.
enum IndoorStepKind: Equatable {
    case walk
    case turnLeft
    case turnRight
    case stairs
    case escalator
    case elevator
    case arrivePlatform
    case arriveExit

    var icon: String {
        switch self {
        case .walk: "arrow.up"
        case .turnLeft: "arrow.turn.up.left"
        case .turnRight: "arrow.turn.up.right"
        case .stairs: "figure.stairs"
        case .escalator: "figure.stairs"
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

extension IndoorStep {
    /// Builds an ordered walkthrough from a routed graph. Turns are emitted only when the
    /// directed edge carries an authored instruction; an isometric diagram alone cannot prove
    /// real-world left/right orientation. Unannotated walking edges collapse into one neutral
    /// "follow the highlighted path" instruction.
    static func build(
        nodeIDs: [String],
        edgeIDs: [String],
        map: StationIndoorMap,
        destinationLineName: String?
    ) -> [IndoorStep] {
        guard nodeIDs.count > 1 else { return [] }
        let nodesByID = Dictionary(uniqueKeysWithValues: map.nodes.map { ($0.id, $0) })
        let edgesByID = Dictionary(uniqueKeysWithValues: map.edges.map { ($0.id, $0) })

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
                title: AppLocalization.text(
                    english: "Follow the highlighted path",
                    simplified: "沿高亮路径前行",
                    traditional: "沿高亮路徑前行"
                ),
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
            let routedEdge = edgeIDs.indices.contains(index - 1) ? edgesByID[edgeIDs[index - 1]] : nil
            guard let toNode = nodesByID[toID],
                  let edge = routedEdge ?? edgeByPair["\(fromID)->\(toID)"] else { continue }
            let isLast = index == nodeIDs.count - 1

            let traversalKind = edge.traversalKind ?? {
                if toNode.kind == .elevator { return .elevator }
                if toNode.kind == .stairs { return .stairs }
                return .walkway
            }()
            if [.elevator, .stairs, .escalator].contains(traversalKind) {
                flushWalk(throughIndex: index - 1)
                let kind: IndoorStepKind = switch traversalKind {
                case .elevator: .elevator
                case .stairs: .stairs
                case .escalator: .escalator
                default: .walk
                }
                let title = switch traversalKind {
                case .elevator:
                    AppLocalization.text(english: "Take the elevator", simplified: "乘坐电梯", traditional: "搭乘電梯")
                case .stairs:
                    AppLocalization.text(english: "Take the stairs", simplified: "走楼梯", traditional: "走樓梯")
                case .escalator:
                    AppLocalization.text(english: "Take the escalator", simplified: "乘坐扶梯", traditional: "搭乘扶梯")
                default:
                    AppLocalization.text(english: "Continue", simplified: "继续前行", traditional: "繼續前行")
                }
                steps.append(IndoorStep(
                    id: nextID,
                    kind: kind,
                    title: title,
                    detail: nil,
                    legMeters: edge.distanceMeters,
                    fromNodeIndex: index - 1,
                    throughNodeIndex: index
                ))
                nextID += 1
                segmentStartIndex = index
                if isLast {
                    steps.append(arrivalStep(
                        id: nextID,
                        node: toNode,
                        detail: nil,
                        destinationLineName: destinationLineName,
                        fromNodeIndex: index,
                        throughNodeIndex: index
                    ))
                }
                continue
            }

            let isForward = edge.fromNodeID == fromID && edge.toNodeID == toID
            let instruction = isForward ? edge.forwardInstruction : edge.reverseInstruction
            if let instruction {
                flushWalk(throughIndex: index - 1)
                let instructionStep = step(
                    id: nextID,
                    instruction: instruction,
                    edge: edge,
                    fromNodeIndex: index - 1,
                    throughNodeIndex: index
                )
                steps.append(instructionStep)
                nextID += 1
                segmentStartIndex = index
            } else {
                pendingMeters += edge.distanceMeters
            }
            if isLast {
                let detail = instruction == nil && pendingMeters > 0.5
                    ? AppLocalization.distance(pendingMeters)
                    : nil
                steps.append(arrivalStep(
                    id: nextID,
                    node: toNode,
                    detail: detail,
                    destinationLineName: destinationLineName,
                    fromNodeIndex: instruction == nil ? segmentStartIndex : index,
                    throughNodeIndex: index
                ))
            }
        }

        return steps
    }

    private static func step(
        id: Int,
        instruction: IndoorDirectedInstruction,
        edge: IndoorEdge,
        fromNodeIndex: Int,
        throughNodeIndex: Int
    ) -> IndoorStep {
        let kind: IndoorStepKind = switch instruction.action {
        case .turnLeft: .turnLeft
        case .turnRight: .turnRight
        case .takeStairs: .stairs
        case .takeEscalator: .escalator
        case .takeElevator: .elevator
        case .continueStraight, .followSigns: .walk
        }
        let title = switch instruction.action {
        case .continueStraight:
            AppLocalization.text(english: "Continue straight", simplified: "直行", traditional: "直行")
        case .turnLeft:
            AppLocalization.text(english: "Turn left", simplified: "向左转", traditional: "向左轉")
        case .turnRight:
            AppLocalization.text(english: "Turn right", simplified: "向右转", traditional: "向右轉")
        case .followSigns:
            AppLocalization.text(english: "Follow the station signs", simplified: "跟随站内标识", traditional: "跟隨站內標識")
        case .takeStairs:
            AppLocalization.text(english: "Take the stairs", simplified: "走楼梯", traditional: "走樓梯")
        case .takeEscalator:
            AppLocalization.text(english: "Take the escalator", simplified: "乘坐扶梯", traditional: "搭乘扶梯")
        case .takeElevator:
            AppLocalization.text(english: "Take the elevator", simplified: "乘坐电梯", traditional: "搭乘電梯")
        }
        return IndoorStep(
            id: id,
            kind: kind,
            title: title,
            detail: instruction.signText ?? AppLocalization.distance(edge.distanceMeters),
            legMeters: edge.distanceMeters,
            fromNodeIndex: fromNodeIndex,
            throughNodeIndex: throughNodeIndex
        )
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

}
