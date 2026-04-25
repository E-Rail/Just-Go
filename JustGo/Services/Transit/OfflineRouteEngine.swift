import Foundation

final class OfflineRouteEngine {
    private var graph: SubwayGraph?

    func loadGraph(cityID: String) {
        // Load from offline data pack
        graph = SubwayGraph()
    }

    func findRoute(
        from origin: Station,
        to destination: Station,
        filter: AccessibilityFilter
    ) -> [Route] {
        guard let graph = graph else { return [] }

        // BFS-based route finding
        let routes = bfsRoutes(
            graph: graph,
            from: origin.stationID,
            to: destination.stationID,
            filter: filter
        )

        return routes
    }

    private func bfsRoutes(
        graph: SubwayGraph,
        from originID: String,
        to destinationID: String,
        filter: AccessibilityFilter
    ) -> [Route] {
        // Simplified BFS implementation
        // In production, this would be a more sophisticated algorithm
        // considering transfers, accessibility, and time

        var visited: Set<String> = []
        var queue: [[String]] = [[originID]]
        var routes: [[String]] = []

        while !queue.isEmpty {
            let path = queue.removeFirst()
            let current = path.last!

            if current == destinationID {
                routes.append(path)
                if routes.count >= 3 { break }
                continue
            }

            if visited.contains(current) { continue }
            visited.insert(current)

            let neighbors = graph.neighbors(of: current, filter: filter)
            for neighbor in neighbors {
                if !visited.contains(neighbor) {
                    queue.append(path + [neighbor])
                }
            }
        }

        // Convert path arrays to Route objects
        return routes.map { path in
            Route(
                id: UUID(),
                origin: "",
                destination: "",
                originStationID: originID,
                destinationStationID: destinationID,
                segments: [],
                totalDuration: Double(path.count - 1) * 180, // 3 min per stop
                totalStops: path.count - 1,
                transferCount: 0,
                accessibilityScore: 1.0,
                isFullyAccessible: true,
                warnings: []
            )
        }
    }
}

// MARK: - Subway Graph

final class SubwayGraph {
    private var adjacency: [String: [String]] = [:]
    private var stationInfo: [String: StationNode] = [:]

    struct StationNode {
        let stationID: String
        let lineIDs: [String]
        let hasElevator: Bool
        let isAccessible: Bool
    }

    func addStation(_ node: StationNode) {
        stationInfo[node.stationID] = node
        if adjacency[node.stationID] == nil {
            adjacency[node.stationID] = []
        }
    }

    func addEdge(from: String, to: String) {
        adjacency[from, default: []].append(to)
        adjacency[to, default: []].append(from)
    }

    func neighbors(of stationID: String, filter: AccessibilityFilter) -> [String] {
        guard let neighbors = adjacency[stationID] else { return [] }

        if filter.requiresElevator || filter.requiresWheelchairAccess {
            return neighbors.filter { id in
                stationInfo[id]?.isAccessible ?? false
            }
        }

        return neighbors
    }
}
