import Foundation

/// What the one map beside the panel shows. The page on top of the panel decides it, through
/// `resolve`, so a pop or an abandoned back-swipe can never leave the map showing a page that is
/// gone: the path only changes once a transition completes.
enum MapFocus {
    /// The city, the rider, and whatever they tap. A station or a place card is browsing too; it
    /// moves the camera once, and the map stays the rider's to pan.
    case browse
    /// A trip being chosen or read: the route over a faded network, with the stops it calls at.
    case route(Route)
    /// A line's own page: the line over a faded network, with its stations.
    case line(LineMap)
    /// A trip under way: the route and the rider, with a camera the guidance page moves.
    case guidance(Route)

    /// The page on top of the panel, as a focus.
    ///
    /// - Parameters:
    ///   - top: The page on top, or nil when the panel is closed.
    ///   - routes: The planner's alternatives, which every route page reads by id.
    ///   - shownAlternative: The alternative a route page is showing, which the rider can switch.
    ///   - lastOpenedRouteID: The route the results page marks as last opened.
    ///   - lineMaps: Line pages' map content, keyed by `LineMap.key`, once each has loaded.
    ///   - guidedRoute: The trip under way, for a guidance page.
    static func resolve(
        top: MapRoute?,
        routes: [Route],
        shownAlternative: (UUID) -> UUID,
        lastOpenedRouteID: UUID?,
        lineMaps: [String: LineMap],
        guidedRoute: Route?
    ) -> MapFocus {
        func route(_ id: UUID) -> MapFocus {
            routes.first { $0.id == id }.map(MapFocus.route) ?? .browse
        }
        switch top {
        case .detail(let id):
            return route(shownAlternative(id))
        case .transfer(let routeID, _), .routeStop(let routeID, _), .confidence(let routeID):
            return route(routeID)
        case .results:
            // Nothing while the plan is still running: the camera stays where the rider was until
            // there is something to show.
            let opened = routes.first { $0.id == lastOpenedRouteID } ?? routes.first
            return opened.map(MapFocus.route) ?? .browse
        case .line(let cityID, let lineID):
            return lineMaps[LineMap.key(cityID: cityID, lineID: lineID)].map(MapFocus.line) ?? .browse
        case .guidance:
            return guidedRoute.map(MapFocus.guidance) ?? .browse
        case .search, .editEndpoint, .station, .place, nil:
            return .browse
        }
    }

    var isBrowsing: Bool {
        if case .browse = self { return true }
        return false
    }

    var isGuidance: Bool {
        if case .guidance = self { return true }
        return false
    }

    /// One camera for the whole trip, so a re-plan mid-trip keeps where the rider was looking.
    static let guidanceCameraKey = "guidance"

    /// Names the camera that belongs to this focus: returning to a focus finds the rider's own pan
    /// again, and a new one starts from its fitted region. Nil while browsing, whose camera is the
    /// browse map's own and is never touched by a focus.
    var cameraKey: String? {
        switch self {
        case .browse: return nil
        case .route(let route): return "route:\(route.id.uuidString)"
        case .line(let line): return "line:\(line.key)"
        case .guidance: return Self.guidanceCameraKey
        }
    }

    /// Where the camera starts when this focus is first shown.
    var fittedRegion: MapVisibleRegion? {
        switch self {
        case .browse: return nil
        case .route(let route), .guidance(let route): return route.previewRegion
        case .line(let line): return line.region
        }
    }

    var route: Route? {
        switch self {
        case .route(let route), .guidance(let route): return route
        case .browse, .line: return nil
        }
    }

    /// The stations a focus draws in place of the browse map's own. Nil while browsing.
    var stations: [Station]? {
        switch self {
        case .browse: return nil
        case .route(let route), .guidance(let route): return route.mapStations
        case .line(let line): return line.stations
        }
    }

    var highlightLines: [MetroLine] {
        if case .line(let line) = self { return [line.line] }
        return []
    }

    /// Whether OpenStreetMap's geometry is drawn beyond the browse network, which then has to say
    /// where it came from (ODbL).
    var drawsMetroGeometry: Bool {
        switch self {
        case .browse: return false
        case .route(let route), .guidance(let route):
            return route.segments.contains { $0.type.isTransit }
        case .line: return true
        }
    }
}

/// One line's page, as the map draws it, handed up by `LineDetailView` once it has loaded.
struct LineMap {
    let key: String
    let line: MetroLine
    /// In the order the line calls at them.
    let stations: [Station]
    let region: MapVisibleRegion?

    static func key(cityID: String, lineID: String) -> String {
        "\(cityID)|\(lineID)"
    }
}
