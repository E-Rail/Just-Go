import MapKit
import SwiftUI

struct MetroGeometryAttributionView: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        // A plain-styled `Button`, not a `Link`: a `Link` tints its whole label with the accent,
        // and `.foregroundStyle(.secondary)` inside it is ignored.
        Button {
            openURL(URL(string: "https://www.openstreetmap.org/copyright")!)
        } label: {
            Text(AppLocalization.localized("Metro geometry © OpenStreetMap contributors"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .floatingChrome(in: Capsule(), isInteractive: true)
                // ODbL attribution is mandatory, so it stays readable and tappable: a 44 pt target
                // around a ~21 pt pill.
                .frame(minHeight: Metrics.minimumTapTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(AppLocalization.localized("Metro geometry © OpenStreetMap contributors"))
    }
}

struct TransitMapView: UIViewRepresentable {
    @Binding var visibleRegion: MapVisibleRegion?
    let stations: [Station]
    /// Draws every supplied station regardless of zoom. The browse map hides ordinary stations
    /// above a 0.1° span, but a route map is handed only the stops the trip calls at, and
    /// whole-trip spans are usually wider than that.
    var alwaysShowsStations = false
    let metroNetworks: [MetroNetwork]
    /// Where `metroNetworks`' interchanges are drawn, by qualified station ID, for those not drawn on
    /// their own point (`MetroNetwork.interchangeSymbolCoordinates()`). Comes with the networks.
    var interchangeSymbols: [String: CLLocationCoordinate2D] = [:]
    let route: Route?
    let showsUserLocation: Bool
    /// How much of the map's top edge the app's floating chrome covers, measured so Dynamic Type
    /// moves it too. MapKit centres inside the layout margins, so without this a rider is centred
    /// behind the search bar. See `ChromeInsetMapView`.
    var topChromeHeight: CGFloat = 0
    /// The same for the bottom edge, where the browse map carries the rider's panel. MapKit puts
    /// its attribution inside the margins too, so this is also what keeps "Legal" out from under
    /// the panel.
    var bottomChromeHeight: CGFloat = 0
    /// The same for the leading edge: on a phone folded side to side, the pane before the crease,
    /// which the browse map gives to its search field and the rider's panel, so the rider is
    /// centred in the pane beyond rather than on the crease.
    var leadingChromeWidth: CGFloat = 0
    /// How heavily to draw the network's lines.
    var networkLineWidth: CGFloat = 6
    /// How strongly the network is drawn: fully while browsing, faintly under a trip or a line the
    /// map is showing, so the city stays legible behind it without competing. Set on the renderers
    /// already on screen; re-adding a city's overlays is the hitch `addPolyline` batches against.
    var networkAlpha: CGFloat = 1
    /// Lines drawn over the network at the weight of a page about one line, where the browse map's
    /// weight reads as a hairline.
    var highlightLines: [MetroLine] = []
    /// Where *MapKit* draws the rider, in the map's GCJ-02 frame, which is not always what Core
    /// Location said (~540 m off in Beijing on a device reporting WGS-84). See
    /// `LocationService.mapSpaceCorrection`.
    var onUserLocationChanged: ((CLLocationCoordinate2D) -> Void)?
    let onRegionChanged: ((MapVisibleRegion) -> Void)?
    /// All the map shows, bounds and not layout margins, for a caller that loads what is in view.
    /// Reported before `onRegionChanged`, so a load that region schedules reads this one.
    var onShownRegionChanged: ((MapVisibleRegion) -> Void)?
    let onStationSelected: (Station) -> Void
    // Two-phase POI tap: `onPlaceTapped` fires synchronously with the feature's name +
    // coordinate so the UI can react instantly; `onPlaceResolved` fires later once the
    // (slow, server-side) MKMapItemRequest has produced the full place card item.
    var onPlaceTapped: ((_ name: String?, _ coordinate: CLLocationCoordinate2D) -> Void)?
    var onPlaceResolved: ((MKMapItem) -> Void)?
    /// A press on ground that is not a POI or a station, so a street corner or a friend's building
    /// can become an endpoint: `selectableMapFeatures` makes only Apple's POIs tappable.
    var onMapLongPressed: ((CLLocationCoordinate2D) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = ChromeInsetMapView(frame: .zero)
        mapView.chromeInsets = UIEdgeInsets(
            top: topChromeHeight, left: leadingChromeWidth, bottom: bottomChromeHeight, right: 0
        )
        mapView.delegate = context.coordinator
        mapView.showsCompass = true
        mapView.showsScale = true
        mapView.pointOfInterestFilter = .includingAll
        mapView.selectableMapFeatures = [.pointsOfInterest]
        mapView.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .flat)
        // On the map view, never the window: a window recogniser sees every touch in the app.
        let longPress = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleLongPress(_:))
        )
        longPress.minimumPressDuration = 0.5
        mapView.addGestureRecognizer(longPress)
        context.coordinator.longPressRecognizer = longPress
        // A renderer's stroke and a symbol's image are resolved colours, frozen when they are made,
        // so both are made again when the appearance changes.
        let coordinator = context.coordinator
        mapView.registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (mapView: MKMapView, _) in
            coordinator.appearanceChanged(on: mapView)
        }
        context.coordinator.sync(parent: self, on: mapView)
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        (mapView as? ChromeInsetMapView)?.chromeInsets = UIEdgeInsets(
            top: topChromeHeight, left: leadingChromeWidth, bottom: bottomChromeHeight, right: 0
        )
        context.coordinator.sync(parent: self, on: mapView)
    }

    static func dismantleUIView(_ mapView: MKMapView, coordinator: Coordinator) {
        coordinator.cancelPOIResolution()
        if let longPress = coordinator.longPressRecognizer {
            mapView.removeGestureRecognizer(longPress)
            coordinator.longPressRecognizer = nil
        }
        mapView.delegate = nil
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var longPressRecognizer: UILongPressGestureRecognizer?
        private var parent: TransitMapView
        private var regionSignature = ""
        private var networkSignature = ""
        private var stationSignature = ""
        private var routeSignature = ""
        private var highlightSignature = ""
        private var appliedNetworkAlpha: CGFloat = 1
        private var markerVisibilityBand = -1
        /// Drives `MapStroke.scale`. Seeded wide so a new map's first stroke suits the zoom it is
        /// actually at.
        private var currentMaxDelta: CLLocationDegrees = 0.05
        /// A station's symbol and its label, by `StationAnnotation.key`: two annotations, so the
        /// label can give way in a collision while the symbol stays.
        private var stationAnnotationsByID: [String: [StationAnnotation]] = [:]
        private var overlayColors: [ObjectIdentifier: UIColor] = [:]
        private var overlayWidths: [ObjectIdentifier: CGFloat] = [:]
        private var overlayDashes: [ObjectIdentifier: [CGFloat]] = [:]
        private var networkOverlays: [MKOverlay] = []
        /// Every network line again as one overlay, drawn under them all. One overlay, because a
        /// casing per line would double what MapKit keeps for a city; under them all, so where two
        /// lines cross neither is cut by the other's casing.
        private var networkCasing: MKMultiPolyline?
        /// Held apart from the rest of the network because these come and go with zoom.
        private var interchangeOverlays: [MKOverlay] = []
        private var routeOverlays: [MKOverlay] = []
        private var highlightOverlays: [MKOverlay] = []
        /// The network's and the interchanges' overlays together, for the fade.
        private var networkOverlayIDs: Set<ObjectIdentifier> = []
        /// Shared by every station with the same lines at the same zoom. A cache the system can
        /// empty: a city's interchanges are a few hundred different rings across the zooms.
        private let stationSymbolImages = NSCache<NSString, UIImage>()
        /// Where each interchange's symbol goes on the networks now loaded. Made again with them.
        private var placements = InterchangeSymbolPlacements(networks: [], symbols: [:])
        private var poiTask: Task<Void, Never>?

        init(parent: TransitMapView) {
            self.parent = parent
        }

        deinit {
            poiTask?.cancel()
        }

        /// `.began` only: acting on `.changed` and `.ended` too would drop a second pin for the
        /// same press.
        @objc
        func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began, let mapView = recognizer.view as? MKMapView else { return }
            let point = recognizer.location(in: mapView)
            parent.onMapLongPressed?(mapView.convert(point, toCoordinateFrom: mapView))
        }

        func cancelPOIResolution() {
            poiTask?.cancel()
            poiTask = nil
        }

        func sync(parent: TransitMapView, on mapView: MKMapView) {
            self.parent = parent
            mapView.showsUserLocation = parent.showsUserLocation
            syncRegion(on: mapView)
            syncNetworks(on: mapView)
            syncNetworkAlpha(on: mapView)
            syncStations(on: mapView)
            syncHighlight(on: mapView)
            syncRoute(on: mapView)
        }

        private func syncRegion(on mapView: MKMapView) {
            guard let visibleRegion = parent.visibleRegion else { return }
            let nextSignature = visibleRegion.signature
            guard nextSignature != regionSignature else { return }
            regionSignature = nextSignature
            mapView.setRegion(visibleRegion.mkCoordinateRegion, animated: true)
        }

        private func syncNetworks(on mapView: MKMapView) {
            let nextSignature = parent.metroNetworks
                .map { "\($0.cityID):\($0.version)" }
                .joined(separator: ",")
            guard nextSignature != networkSignature else { return }
            networkSignature = nextSignature
            mapView.removeOverlays(networkOverlays)
            mapView.removeOverlays(interchangeOverlays)
            clearOverlayMetadata(networkOverlays)
            clearOverlayMetadata(interchangeOverlays)
            if let networkCasing {
                mapView.removeOverlay(networkCasing)
                clearOverlayMetadata([networkCasing])
            }
            networkOverlays = []
            interchangeOverlays = []
            networkCasing = nil
            placements = InterchangeSymbolPlacements(networks: parent.metroNetworks, symbols: parent.interchangeSymbols)

            addNetworks(parent.metroNetworks)
            addInterchanges(across: parent.metroNetworks)
            if !networkOverlays.isEmpty {
                let casing = MKMultiPolyline(networkOverlays.compactMap { $0 as? MKPolyline })
                overlayWidths[ObjectIdentifier(casing)] = parent.networkLineWidth
                networkCasing = casing
            }
            // Before anything is added: MapKit asks for a renderer during `addOverlays`, and
            // `rendererFor` fades only what is in this set.
            networkOverlayIDs = Set(
                (networkOverlays + interchangeOverlays + [networkCasing].compactMap { $0 }).map { ObjectIdentifier($0) }
            )
            if let networkCasing {
                // First, so it is under every line: overlays in one level draw in the order added.
                mapView.addOverlays([networkCasing] + networkOverlays, level: .aboveRoads)
            }
            syncInterchangeVisibility(on: mapView)
        }

        /// Fades the network in place. A renderer MapKit has not made yet takes the alpha when it is
        /// made, in `rendererFor`.
        private func syncNetworkAlpha(on mapView: MKMapView) {
            guard parent.networkAlpha != appliedNetworkAlpha else { return }
            appliedNetworkAlpha = parent.networkAlpha
            for overlay in networkOverlays + interchangeOverlays + [networkCasing].compactMap({ $0 }) {
                guard let renderer = mapView.renderer(for: overlay) else { continue }
                renderer.alpha = appliedNetworkAlpha
                renderer.setNeedsDisplay()
            }
        }

        private func syncHighlight(on mapView: MKMapView) {
            let nextSignature = parent.highlightLines.map(\.id).joined(separator: ",")
            guard nextSignature != highlightSignature else { return }
            highlightSignature = nextSignature
            mapView.removeOverlays(highlightOverlays)
            clearOverlayMetadata(highlightOverlays)
            highlightOverlays = []
            for line in parent.highlightLines {
                for path in line.paths where path.count >= 2 {
                    addPolyline(
                        path.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) },
                        colorHex: line.colorHex,
                        lineWidth: 9,
                        simplify: false,
                        collection: &highlightOverlays
                    )
                }
            }
            if !highlightOverlays.isEmpty {
                mapView.addOverlays(highlightOverlays, level: .aboveLabels)
            }
        }

        /// Interchange links are drawn exactly while the stations they join are: a link is an
        /// instruction to walk somewhere, meaningful only when both ends are visible. The same
        /// threshold as an ordinary station.
        private func syncInterchangeVisibility(on mapView: MKMapView) {
            guard !interchangeOverlays.isEmpty else { return }
            let maxDelta = max(mapView.region.span.latitudeDelta, mapView.region.span.longitudeDelta)
            let shouldShow = maxDelta <= StationAnnotationStyle.ordinaryStationMaxDelta
            let isShowing = mapView.overlays.contains { overlay in
                interchangeOverlays.contains { $0 === overlay }
            }
            guard shouldShow != isShowing else { return }
            if shouldShow {
                mapView.addOverlays(interchangeOverlays, level: .aboveRoads)
            } else {
                mapView.removeOverlays(interchangeOverlays)
            }
        }

        /// A station has annotations exactly while it is drawn, so nothing hidden is left on the
        /// map to take part in a collision. Runs again when the zoom crosses a band, which is what
        /// moves a station in or out of view.
        private func syncStations(on mapView: MKMapView) {
            let maxDelta = max(mapView.region.span.latitudeDelta, mapView.region.span.longitudeDelta)
            let drawn = parent.stations.filter { station in
                StationAnnotationStyle.isVisible(
                    at: maxDelta,
                    isTransfer: station.isTransferStation,
                    alwaysVisible: parent.alwaysShowsStations
                )
            }
            // O(1)-ish change check via a hash of what is to be drawn, instead of building a
            // multi-KB joined string on every SwiftUI invalidation.
            var hasher = Hasher()
            // An interchange's symbol is placed against the loaded lines, so it can move when they
            // change.
            hasher.combine(networkSignature)
            hasher.combine(drawn.count)
            for station in drawn {
                hasher.combine(station.stationID)
                hasher.combine(station.isTransferStation)
                for line in station.lines { hasher.combine(line.colorHex) }
            }
            let nextSignature = String(hasher.finalize())
            guard nextSignature != stationSignature else { return }
            stationSignature = nextSignature

            // Keyed by what is drawn, not the station alone: a trip's map hands over the same
            // station with only the lines the trip rides, and that is a different symbol, possibly
            // in a different place.
            let desiredByID = Dictionary(
                drawn.map { station in
                    let coordinate = placements.coordinate(for: station)
                    return (StationAnnotation.key(for: station, at: coordinate), (station, coordinate))
                },
                uniquingKeysWith: { first, _ in first }
            )
            let desiredIDs = Set(desiredByID.keys)
            let currentIDs = Set(stationAnnotationsByID.keys)

            // Remove only the annotations that are gone; keep (and preserve the dequeued views of)
            // the ones that remain, instead of clearing and re-adding everything.
            let removedIDs = currentIDs.subtracting(desiredIDs)
            if !removedIDs.isEmpty {
                mapView.removeAnnotations(removedIDs.flatMap { stationAnnotationsByID.removeValue(forKey: $0) ?? [] })
            }

            let addedIDs = desiredIDs.subtracting(currentIDs)
            if !addedIDs.isEmpty {
                let added = addedIDs.flatMap { id -> [StationAnnotation] in
                    guard let (station, coordinate) = desiredByID[id] else { return [] }
                    let pair = [
                        StationAnnotation(station: station, coordinate: coordinate, part: .symbol),
                        StationAnnotation(station: station, coordinate: coordinate, part: .label)
                    ]
                    stationAnnotationsByID[id] = pair
                    return pair
                }
                mapView.addAnnotations(added)
            }
        }

        private func syncRoute(on mapView: MKMapView) {
            // With the networks, because a ride's connectors end at its stations' placed symbols.
            let nextSignature = "\(parent.route?.id.uuidString ?? "no-route")|\(networkSignature)"
            guard nextSignature != routeSignature else { return }
            routeSignature = nextSignature
            mapView.removeOverlays(routeOverlays)
            clearOverlayMetadata(routeOverlays)
            routeOverlays = []
            if let route = parent.route {
                addRoute(route)
            }
            if !routeOverlays.isEmpty {
                mapView.addOverlays(routeOverlays, level: .aboveLabels)
            }
        }

        private func clearOverlayMetadata(_ overlays: [MKOverlay]) {
            for overlay in overlays {
                overlayColors.removeValue(forKey: ObjectIdentifier(overlay))
                overlayWidths.removeValue(forKey: ObjectIdentifier(overlay))
                overlayDashes.removeValue(forKey: ObjectIdentifier(overlay))
            }
        }

        /// Every loaded pack's lines, each stretch of track drawn once. Neighbouring packs ship
        /// their shared corridors byte for byte, and identity is the path's own points, so this
        /// collapses a way only onto a copy of itself: the drawing half of `canonicalStationIDs`
        /// and `canonicalLineIDs`.
        private func addNetworks(_ networks: [MetroNetwork]) {
            var drawn = Set<Int>()
            for network in networks {
                for line in network.lines {
                    for path in line.paths where path.count >= 2 {
                        var hasher = Hasher()
                        hasher.combine(line.colorHex)
                        hasher.combine(path.count)
                        for point in path {
                            hasher.combine(point.latitude)
                            hasher.combine(point.longitude)
                        }
                        guard drawn.insert(hasher.finalize()).inserted else { continue }
                        addPolyline(
                            path.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) },
                            colorHex: line.colorHex,
                            lineWidth: parent.networkLineWidth,
                            simplify: false,
                            collection: &networkOverlays
                        )
                    }
                }
            }
        }

        /// The links between two stations riders treat as one interchange, drawn on the network so
        /// a rider sees 广安门内 and 牛街 connected before planning through them. Resolved across every
        /// loaded network, because a link's halves can be in different packs (Shenzhen's 罗湖 and
        /// Hong Kong's 羅湖).
        private func addInterchanges(across networks: [MetroNetwork]) {
            var stationsByID: [String: (station: MetroStation, cityID: String)] = [:]
            for network in networks {
                for station in network.stations where stationsByID[station.id] == nil {
                    stationsByID[station.id] = (station, network.cityID)
                }
            }
            // Ends where each station's symbol is drawn.
            func coordinate(of stationID: String) -> CLLocationCoordinate2D? {
                guard let (station, cityID) = stationsByID[stationID] else { return nil }
                return placements.coordinate(
                    stationID: MetroStationIdentifier.qualified(cityID: cityID, stationID: station.id),
                    at: station.coordinate
                )
            }
            // A cross-pack link is written into both of its packs, so it arrives twice.
            var drawn = Set<String>()
            for link in networks.flatMap(\.interchanges) {
                guard drawn.insert("\(link.fromStationID)|\(link.toStationID)").inserted,
                      let from = coordinate(of: link.fromStationID),
                      let to = coordinate(of: link.toStationID) else { continue }
                addPolyline(
                    [from, to],
                    colorHex: SegmentType.transfer.colorHex(line: nil),
                    lineWidth: 5,
                    dashPattern: SegmentType.transfer.dash(width: 5),
                    simplify: false,
                    collection: &interchangeOverlays
                )
            }
        }

        private func addRoute(_ route: Route) {
            // Where this map draws each stop, by the same rule as its symbol.
            let stopCoordinates = Dictionary(
                route.mapStations.map { ($0.stationID, placements.coordinate(for: $0)) },
                uniquingKeysWith: { first, _ in first }
            )
            for segment in route.segments {
                let coordinates = segment.drawableCoordinates.map {
                    CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                }
                guard coordinates.count >= 2 else { continue }
                // Thinner than the track it feeds, the way a walking route is drawn everywhere: a
                // first or last mile doubles back within a couple of streets, and a stroke as wide
                // as the ride's fills that whole area in one colour instead of showing the path.
                let width: CGFloat = segment.type.isAccessLeg ? 5 : 6
                let dash = segment.type.dash(width: width)
                // A dark casing under every solid leg, because a line's colour is data and some of
                // it is the same grey the basemap draws roads with. Solid legs only: behind a
                // dashed one it fills the gaps back in.
                if dash.isEmpty {
                    addPolyline(
                        coordinates,
                        colorHex: "#0B0B0F",
                        lineWidth: 10,
                        alpha: 0.55,
                        simplify: true,
                        collection: &routeOverlays
                    )
                }
                addPolyline(
                    coordinates,
                    colorHex: segment.colorHex,
                    lineWidth: width,
                    dashPattern: dash,
                    simplify: true,
                    collection: &routeOverlays
                )
                addStationConnectors(for: segment, drawn: coordinates, stopCoordinates: stopCoordinates)
            }
        }

        /// Joins a ride's drawn track to the stations it calls at, in the transfer grey and dash,
        /// never the line's colour. A station node can sit hundreds of metres from its rail (顺义 is
        /// 272 m from 15号线's track). The ride draws only the track; bending it out to the platform
        /// would spike, and leaving the gap looks broken. Colour means "the train runs here", and
        /// this is not track.
        ///
        /// Each connector ends at the station's symbol, which for an interchange is where its lines
        /// meet rather than the station's own point (`InterchangePlacement`).
        private func addStationConnectors(
            for segment: RouteSegment,
            drawn: [CLLocationCoordinate2D],
            stopCoordinates: [String: CLLocationCoordinate2D]
        ) {
            guard segment.type.isTransit,
                  let first = segment.stationStops.first,
                  let last = segment.stationStops.last,
                  let trackStart = drawn.first,
                  let trackEnd = drawn.last else { return }
            func drawnCoordinate(of stop: RouteStationStop) -> CLLocationCoordinate2D? {
                stopCoordinates[stop.stationID] ?? stop.coordinate.map {
                    CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                }
            }
            guard let boarding = drawnCoordinate(of: first),
                  let alighting = drawnCoordinate(of: last) else { return }
            for (station, track) in [(boarding, trackStart), (alighting, trackEnd)] {
                // Below this they are the same place at any zoom, and an overlay per station per
                // leg is not free.
                guard station.distance(to: track) >= 15 else { continue }
                addPolyline(
                    [station, track],
                    colorHex: SegmentType.transfer.colorHex(line: nil),
                    lineWidth: 7,
                    dashPattern: SegmentType.transfer.dash(width: 7),
                    simplify: false,
                    collection: &routeOverlays
                )
            }
        }

        // Builds a polyline and records it for the caller's single batched `addOverlays(_:level:)`:
        // adding overlays one at a time costs MapKit per-insertion bookkeeping, a visible hitch for
        // a large city.
        private func addPolyline(
            _ coordinates: [CLLocationCoordinate2D],
            colorHex: String,
            lineWidth: CGFloat,
            dashPattern: [CGFloat] = [],
            alpha: CGFloat = 1,
            simplify: Bool,
            collection: inout [MKOverlay]
        ) {
            let displayCoordinates = simplify ? simplifiedCoordinates(coordinates) : coordinates
            let polyline = MKPolyline(coordinates: displayCoordinates, count: displayCoordinates.count)
            overlayColors[ObjectIdentifier(polyline)] = UIColor(Color(hex: colorHex)).withAlphaComponent(alpha)
            overlayWidths[ObjectIdentifier(polyline)] = lineWidth
            overlayDashes[ObjectIdentifier(polyline)] = dashPattern.isEmpty ? nil : dashPattern
            collection.append(polyline)
        }

        private func simplifiedCoordinates(
            _ coordinates: [CLLocationCoordinate2D],
            maxPoints: Int = 520,
            minDistanceMeters: Double = 12
        ) -> [CLLocationCoordinate2D] {
            guard coordinates.count > maxPoints else { return coordinates }

            var simplified: [CLLocationCoordinate2D] = []
            simplified.reserveCapacity(maxPoints)

            for coordinate in coordinates {
                guard let previous = simplified.last else {
                    simplified.append(coordinate)
                    continue
                }

                if previous.distance(to: coordinate) >= minDistanceMeters {
                    simplified.append(coordinate)
                }
            }

            if let last = coordinates.last {
                let currentLast = simplified.last
                if currentLast?.latitude != last.latitude || currentLast?.longitude != last.longitude {
                    simplified.append(last)
                }
            }

            if simplified.count > maxPoints {
                let stride = max(1, simplified.count / maxPoints)
                simplified = simplified.enumerated().compactMap { index, coordinate in
                    index == 0 || index == simplified.count - 1 || index.isMultiple(of: stride) ? coordinate : nil
                }
            }

            return simplified.count >= 2 ? simplified : coordinates
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let annotation = annotation as? StationAnnotation else { return nil }

            let view: MKAnnotationView
            switch annotation.part {
            case .symbol:
                view = mapView.dequeueReusableAnnotationView(withIdentifier: "station.symbol") as? StationSymbolView ??
                    StationSymbolView(annotation: annotation, reuseIdentifier: "station.symbol")
            case .label:
                view = mapView.dequeueReusableAnnotationView(withIdentifier: "station.label") as? StationLabelView ??
                    StationLabelView(annotation: annotation, reuseIdentifier: "station.label")
            }
            view.annotation = annotation
            configure(view, for: annotation, on: mapView)
            return view
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let annotation = view.annotation else { return }
            if let station = (annotation as? StationAnnotation)?.station {
                // A station tap supersedes any in-flight POI resolve; stop it.
                cancelPOIResolution()
                parent.onStationSelected(station)
                mapView.deselectAnnotation(annotation, animated: false)
            } else if let feature = annotation as? MKMapFeatureAnnotation,
                      feature.featureType == .pointOfInterest {
                // Surface the tap at once from the feature's title and coordinate, without waiting
                // on the resolve.
                parent.onPlaceTapped?(feature.title, feature.coordinate)
                // Resolve the POI to a full `MKMapItem` in the background. Deselect only after, so
                // the feature stays valid.
                poiTask?.cancel()
                poiTask = Task { @MainActor [weak self, weak mapView] in
                    let mapItem = try? await MKMapItemRequest(mapFeatureAnnotation: feature).mapItem
                    mapView?.deselectAnnotation(feature, animated: false)
                    // `MKMapItemRequest` ignores task cancellation, so guard explicitly against a
                    // superseded tap; `weak self` keeps a cancelled task from retaining the
                    // coordinator.
                    guard !Task.isCancelled, let self, let mapItem else { return }
                    self.parent.onPlaceResolved?(mapItem)
                }
            }
        }

        func mapView(_ mapView: MKMapView, didUpdate userLocation: MKUserLocation) {
            guard let coordinate = userLocation.location?.coordinate else { return }
            parent.onUserLocationChanged?(coordinate)
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            guard parent.visibleRegion != nil else { return }
            let region = mapView.region
            let visibleRegion = MapVisibleRegion(
                center: region.center,
                latitudeDelta: region.span.latitudeDelta,
                longitudeDelta: region.span.longitudeDelta
            )
            regionSignature = visibleRegion.signature
            // Marker size and visibility only change when `maxDelta` crosses a threshold, so skip
            // the sweep while panning at a fixed zoom.
            let maxDelta = max(region.span.latitudeDelta, region.span.longitudeDelta)
            let band = markerBand(for: maxDelta)
            if band != markerVisibilityBand {
                markerVisibilityBand = band
                currentMaxDelta = maxDelta
                syncStations(on: mapView)
                refreshStationViews(on: mapView)
                syncInterchangeVisibility(on: mapView)
                // Safe on the marker band: its breakpoints (0.055, 0.1, 0.18, 0.8) include
                // `MapStroke.scale`'s (0.055, 0.18, 0.8). Keep that true if either set moves.
                refreshOverlayWidths(on: mapView)
            }
            if let onShownRegionChanged = parent.onShownRegionChanged {
                let shown = mapView.convert(mapView.bounds, toRegionFrom: mapView)
                onShownRegionChanged(MapVisibleRegion(
                    center: shown.center,
                    latitudeDelta: shown.span.latitudeDelta,
                    longitudeDelta: shown.span.longitudeDelta
                ))
            }
            parent.onRegionChanged?(visibleRegion)
        }

        /// The network's own stroke at the current zoom, which the stations on it are sized from.
        private var networkStroke: CGFloat {
            MapStroke.width(parent.networkLineWidth, at: currentMaxDelta)
        }

        private func applyStroke(to renderer: MKOverlayPathRenderer, overlay: MKOverlay) {
            let key = ObjectIdentifier(overlay)
            let width = overlayWidths[key] ?? 5
            let stroke = MapStroke.width(width, at: currentMaxDelta)
            renderer.lineJoin = .round
            guard overlay !== networkCasing else {
                renderer.lineWidth = MapStroke.casingWidth(over: stroke)
                renderer.lineCap = .round
                return
            }
            renderer.lineWidth = stroke
            // Against the width actually drawn, floor included, so the dash keeps the proportions
            // `SegmentType.dash(width:)` set. Butt caps under a dash, because a round one overhangs
            // half a width past each end and closes the gaps into a string of blobs; round on a
            // solid leg, where it caps the dark casing over the line's own end.
            let dash = overlayDashes[key]
            renderer.lineDashPattern = dash?.map { NSNumber(value: Double($0 * stroke / width)) }
            renderer.lineCap = dash == nil ? .round : .butt
        }

        /// Re-strokes overlays already on screen: MapKit hands back its existing renderers, so this
        /// sets two numbers each and redraws.
        private func refreshOverlayWidths(on mapView: MKMapView) {
            for overlay in mapView.overlays {
                guard let renderer = mapView.renderer(for: overlay) as? MKOverlayPathRenderer else { continue }
                applyStroke(to: renderer, overlay: overlay)
                renderer.setNeedsDisplay()
            }
        }

        private func markerBand(for maxDelta: CLLocationDegrees) -> Int {
            // Breakpoints: `MapStroke.scale`'s (0.055, 0.18, 0.8), which size a station's symbol
            // and its label, and the visibility thresholds (ordinary ≤ 0.1, transfer ≤ 0.8).
            if maxDelta <= 0.055 { return 0 }
            if maxDelta <= 0.1 { return 1 }
            if maxDelta <= 0.18 { return 2 }
            if maxDelta <= 0.8 { return 3 }
            return 4
        }

        /// The casing and every symbol's rim are the page's background in the appearance they were
        /// made for, so both are made again.
        func appearanceChanged(on mapView: MKMapView) {
            if let networkCasing, let renderer = mapView.renderer(for: networkCasing) as? MKOverlayPathRenderer {
                renderer.strokeColor = MapStroke.casingColor(in: mapView)
                renderer.setNeedsDisplay()
            }
            refreshStationViews(on: mapView)
        }

        private func refreshStationViews(on mapView: MKMapView) {
            for annotation in mapView.annotations {
                guard let annotation = annotation as? StationAnnotation,
                      let view = mapView.view(for: annotation) else {
                    continue
                }
                configure(view, for: annotation, on: mapView)
            }
        }

        private func configure(_ view: MKAnnotationView, for annotation: StationAnnotation, on mapView: MKMapView) {
            let station = annotation.station
            let symbol = StationSymbol(lineWidth: networkStroke, isTransfer: station.isTransferStation)
            view.canShowCallout = false
            if let view = view as? StationSymbolView {
                // Always drawn: a station is where the rider can board, whatever is beside it.
                view.displayPriority = .required
                view.collisionMode = .circle
                let isDark = mapView.traitCollection.userInterfaceStyle == .dark
                let key = "\(annotation.ringColorHexes.joined(separator: ","))|\(symbol.id)|\(isDark)"
                view.configure(station: station, symbol: symbol, key: key) {
                    self.stationSymbolImage(symbol, colorHexes: annotation.ringColorHexes, key: key, on: mapView)
                }
            } else if let view = view as? StationLabelView {
                // A name gives way to another station's symbol and to a busier station's name, so
                // names never pile up: MapKit hides the lower priority of two views that collide.
                view.displayPriority = station.isTransferStation ? .defaultHigh : .defaultLow
                view.collisionMode = .rectangle
                view.configure(station: station, symbol: symbol, textSize: StationAnnotationStyle.labelSize(at: currentMaxDelta))
            }
        }

        private func stationSymbolImage(
            _ symbol: StationSymbol,
            colorHexes: [String],
            key: String,
            on mapView: MKMapView
        ) -> UIImage {
            if let cached = stationSymbolImages.object(forKey: key as NSString) {
                return cached
            }
            let image = symbol.image(
                ringColors: colorHexes.map { UIColor(Color(hex: $0)) },
                rimColor: MapStroke.casingColor(in: mapView)
            )
            stationSymbolImages.setObject(image, forKey: key as NSString)
            return image
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            let renderer: MKOverlayPathRenderer
            if let casing = overlay as? MKMultiPolyline {
                renderer = MKMultiPolylineRenderer(multiPolyline: casing)
                renderer.strokeColor = MapStroke.casingColor(in: mapView)
            } else if let polyline = overlay as? MKPolyline {
                renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = overlayColors[ObjectIdentifier(polyline)] ?? .systemBlue
            } else {
                return MKOverlayRenderer(overlay: overlay)
            }
            applyStroke(to: renderer, overlay: overlay)
            if networkOverlayIDs.contains(ObjectIdentifier(overlay)) {
                renderer.alpha = parent.networkAlpha
            }
            return renderer
        }
    }
}

/// The map's strokes, and the station symbols that sit on them, in multiples of one line's width,
/// so a line, its casing and its stations keep their proportions at every zoom.
private enum MapStroke {
    /// How much to shrink every stroke at this zoom. A renderer's `lineWidth` is in screen points,
    /// so at the whole trip's zoom an unshrunk leg is a band across the city.
    static func scale(for maxDelta: CLLocationDegrees) -> CGFloat {
        switch maxDelta {
        case ..<0.055: return 1
        case ..<0.18: return 0.85
        case ..<0.8: return 0.62
        default: return 0.45
        }
    }

    /// Floored so a hairline never disappears entirely at the widest zooms.
    static func width(_ width: CGFloat, at maxDelta: CLLocationDegrees) -> CGFloat {
        max(1.5, width * scale(for: maxDelta))
    }

    /// A casing shows a quarter of its line's width on each side.
    static func casingWidth(over lineWidth: CGFloat) -> CGFloat {
        lineWidth * 1.5
    }

    /// What a network line is cased in and a station symbol rimmed with: the background of the
    /// appearance the map is in, so a line is cut out of the basemap rather than outlined on it.
    /// Resolved, because a renderer and an image both keep the colour they were given.
    static func casingColor(in mapView: MKMapView) -> UIColor {
        UIColor.systemBackground.resolvedColor(with: mapView.traitCollection)
    }
}

/// A station on the map: a white disc ringed in the colours of its lines, a larger one where
/// lines meet. Sized from the stroke of the line it sits on.
private struct StationSymbol {
    /// The network's stroke at the zoom the symbol is drawn for.
    let lineWidth: CGFloat
    let isTransfer: Bool

    /// Across the ring: twice the line for a stop, three times for an interchange.
    var ringDiameter: CGFloat { lineWidth * (isTransfer ? 3 : 2) }
    var ringWidth: CGFloat { ringDiameter / 6 }
    /// The same quarter of the line's width its casing shows.
    var rimWidth: CGFloat { lineWidth / 4 }
    /// Whole points, so the image is not resampled onto the view's pixels.
    var side: CGFloat { (ringDiameter + rimWidth * 2).rounded(.up) }
    var id: String { "\(isTransfer)-\(lineWidth)" }

    /// - Parameter ringColors: One per line, in the station's own order, clockwise from the top.
    ///   Empty draws a neutral ring, for a station whose lines are not known here.
    func image(ringColors: [UIColor], rimColor: UIColor) -> UIImage {
        let center = CGPoint(x: side / 2, y: side / 2)
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { renderer in
            let context = renderer.cgContext
            func fillDisc(_ diameter: CGFloat, _ color: UIColor) {
                context.setFillColor(color.cgColor)
                context.fillEllipse(in: CGRect(
                    x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter
                ))
            }
            fillDisc(ringDiameter + rimWidth * 2, rimColor)
            // The first colour all the way round and the others as wedges over it, so the seam
            // between two wedges never shows the rim through.
            fillDisc(ringDiameter, ringColors.first ?? .darkGray)
            let sweep = 2 * CGFloat.pi / CGFloat(max(ringColors.count, 1))
            for (index, color) in ringColors.enumerated().dropFirst() {
                let start = -CGFloat.pi / 2 + sweep * CGFloat(index)
                context.move(to: center)
                context.addArc(
                    center: center, radius: ringDiameter / 2,
                    startAngle: start, endAngle: start + sweep, clockwise: false
                )
                context.closePath()
                context.setFillColor(color.cgColor)
                context.fillPath()
            }
            // White in both appearances: on a dark map a station is still the bright dot.
            fillDisc(ringDiameter - ringWidth * 2, .white)
        }
    }
}

/// Where each interchange's symbol is drawn on the loaded networks: where its lines meet
/// (`InterchangePlacement`). The networks' own placements arrive with them, worked out off the main
/// thread; only a trip drawing two lines of a larger interchange is placed here, when first drawn,
/// and remembered until the networks change.
///
/// Lines are looked up across every loaded network, not only the station's own: routing gives a
/// corridor two packs share one pack's line ID.
private final class InterchangeSymbolPlacements {
    private let symbols: [String: CLLocationCoordinate2D]
    private var stationsByID: [String: MetroStation] = [:]
    private var linesByID: [String: MetroLine] = [:]
    private var tracksByLineID: [String: [[CLLocationCoordinate2D]]] = [:]
    private var placed: [String: CLLocationCoordinate2D] = [:]

    /// - Parameter symbols: The networks' placements, by qualified station ID.
    init(networks: [MetroNetwork], symbols: [String: CLLocationCoordinate2D]) {
        self.symbols = symbols
        for network in networks {
            for station in network.stations {
                stationsByID[MetroStationIdentifier.qualified(cityID: network.cityID, stationID: station.id)] = station
            }
            for line in network.lines where linesByID[line.id] == nil {
                linesByID[line.id] = line
            }
        }
    }

    /// Where `station`'s symbol goes. Drawn with all its lines (browsing), or with the one line of a
    /// trip passing through, it is where its network placed it; drawn with two of its lines (a trip
    /// changing between them), it is where those two meet.
    func coordinate(for station: Station) -> CLLocationCoordinate2D {
        guard station.isTransferStation else { return station.coordinate }
        let ownLineIDs = Set(stationsByID[station.stationID]?.lineIDs ?? []).filter { linesByID[$0] != nil }
        let drawnLineIDs = Set(station.lines.map(\.lineID)).filter { linesByID[$0] != nil }
        if drawnLineIDs.count > 1, drawnLineIDs != ownLineIDs {
            return coordinate(stationID: station.stationID, at: station.coordinate, lineIDs: drawnLineIDs)
        }
        return coordinate(stationID: station.stationID, at: station.coordinate)
    }

    /// A station drawn with all its lines.
    ///
    /// - Parameter stationID: The qualified ID (`MetroStationIdentifier.qualified`).
    func coordinate(stationID: String, at coordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        symbols[stationID] ?? coordinate
    }

    private func coordinate(
        stationID: String,
        at coordinate: CLLocationCoordinate2D,
        lineIDs: Set<String>
    ) -> CLLocationCoordinate2D {
        let ordered = lineIDs.sorted()
        let key = ([stationID] + ordered).joined(separator: "|")
        if let known = placed[key] { return known }
        let result = InterchangePlacement.place(station: coordinate, lineTracks: ordered.compactMap(tracks(of:))).coordinate
        placed[key] = result
        return result
    }

    private func tracks(of lineID: String) -> [[CLLocationCoordinate2D]]? {
        if let known = tracksByLineID[lineID] { return known }
        guard let line = linesByID[lineID] else { return nil }
        let tracks = line.paths.map { $0.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) } }
        tracksByLineID[lineID] = tracks
        return tracks
    }
}

private final class StationAnnotation: NSObject, MKAnnotation {
    enum Part {
        case symbol
        case label
    }

    let station: Station
    let part: Part
    /// The station's line colours, each once: two lines that share a colour are one arc of the ring.
    let ringColorHexes: [String]
    // Resolved once (zh-Hant involves a Hans→Hant transform); MapKit reads title and subtitle
    // repeatedly. On the symbol only: it is the part VoiceOver reads.
    let title: String?
    let subtitle: String?
    /// Where the symbol is drawn: the station's own point, or for an interchange where its lines
    /// meet (`InterchangeSymbolPlacements`). The label sits beside it.
    let coordinate: CLLocationCoordinate2D

    /// The station and how it is drawn, so one station drawn two ways is two annotations.
    static func key(for station: Station, at coordinate: CLLocationCoordinate2D) -> String {
        "\(station.stationID)|\(station.isTransferStation)|\(ringColorHexes(of: station).joined(separator: ","))" +
            "|\(coordinate.latitude),\(coordinate.longitude)"
    }

    private static func ringColorHexes(of station: Station) -> [String] {
        var seen = Set<String>()
        return station.lines.map { $0.colorHex.uppercased() }.filter { seen.insert($0).inserted }
    }

    init(station: Station, coordinate: CLLocationCoordinate2D, part: Part) {
        self.station = station
        self.coordinate = coordinate
        self.part = part
        self.ringColorHexes = Self.ringColorHexes(of: station)
        self.title = part == .symbol ? station.localizedName : nil
        self.subtitle = part == .symbol
            ? station.uniqueLogicalLines.map(\.localizedName).joined(separator: " / ")
            : nil
        super.init()
    }
}

/// What two station views keep clear of each other. MapKit tests a collision on a view's alignment
/// rectangle, and both station views state theirs: one left at zero is given a margin of MapKit's
/// own (4 points, measured on iOS 27.2), wide enough to hide every name beside its own symbol.
private final class StationSymbolView: MKAnnotationView {
    private var configurationKey = ""
    private var rimWidth: CGFloat = 0

    /// The ring, without the rim around it.
    override var alignmentRectInsets: UIEdgeInsets {
        UIEdgeInsets(top: rimWidth, left: rimWidth, bottom: rimWidth, right: rimWidth)
    }

    /// - Parameter image: Made only when `key` differs from what the view already shows.
    func configure(station: Station, symbol: StationSymbol, key: String, image: () -> UIImage) {
        accessibilityLabel = station.accessibilityLabel
        guard key != configurationKey else { return }
        configurationKey = key
        rimWidth = symbol.rimWidth
        // An annotation view takes its image's size and centres it on the coordinate.
        self.image = image()
    }
}

/// A station's name, beside its symbol. An annotation of its own so that MapKit can hide it in a
/// collision and leave the symbol.
private final class StationLabelView: MKAnnotationView {
    private let tagView = UIView()
    private let chineseLabel = UILabel()
    private let englishLabel = UILabel()
    private var configurationKey = ""

    /// Wider than the tag by a hairline on every side, so two names are never drawn touching.
    /// `symbolGap` is more than this, which is what keeps a name clear of its own symbol.
    override var alignmentRectInsets: UIEdgeInsets {
        UIEdgeInsets(top: -Metrics.hairline, left: -Metrics.hairline, bottom: -Metrics.hairline, right: -Metrics.hairline)
    }

    /// From the symbol's edge to the tag's.
    private static let symbolGap = Metrics.s / 2

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)

        tagView.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.9)
        tagView.layer.borderWidth = 0.5
        applyBorderColor()
        // `UIView.backgroundColor` re-resolves with the appearance; a `.cgColor` is resolved once
        // and frozen, so it is refreshed here when the in-app Light/Dark setting changes.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: StationLabelView, _) in
            view.applyBorderColor()
        }
        addSubview(tagView)
        tagView.addSubview(chineseLabel)
        tagView.addSubview(englishLabel)
        // The symbol is the station's one accessibility element; this would read it twice.
        isAccessibilityElement = false
        accessibilityElementsHidden = true
    }

    private func applyBorderColor() {
        tagView.layer.borderColor = UIColor.separator.resolvedColor(with: traitCollection).cgColor
    }

    required init?(coder: NSCoder) {
        nil
    }

    func configure(station: Station, symbol: StationSymbol, textSize: CGFloat) {
        let nextKey = "\(station.stationID):\(symbol.id):\(textSize)"
        guard nextKey != configurationKey else { return }
        configurationKey = nextKey

        chineseLabel.text = station.localizedName
        chineseLabel.font = .systemFont(ofSize: textSize, weight: .semibold)
        chineseLabel.textColor = .label
        chineseLabel.sizeToFit()

        englishLabel.text = station.alternateLocalizedName
        englishLabel.font = .systemFont(ofSize: max(7, textSize - 3), weight: .regular)
        englishLabel.textColor = .secondaryLabel
        englishLabel.isHidden = englishLabel.text?.isEmpty != false
        englishLabel.sizeToFit()

        let horizontalPadding: CGFloat = 6
        let verticalPadding: CGFloat = 3
        let labelWidth = max(chineseLabel.bounds.width, englishLabel.isHidden ? 0 : englishLabel.bounds.width)
        let labelHeight = chineseLabel.bounds.height + (englishLabel.isHidden ? 0 : englishLabel.bounds.height + 1)
        let tagSize = CGSize(width: labelWidth + horizontalPadding * 2, height: labelHeight + verticalPadding * 2)

        bounds = CGRect(origin: .zero, size: tagSize)
        tagView.frame = bounds
        tagView.layer.cornerRadius = min(8, tagSize.height / 2)
        chineseLabel.frame.origin = CGPoint(x: horizontalPadding, y: verticalPadding)
        englishLabel.frame.origin = CGPoint(
            x: horizontalPadding,
            y: chineseLabel.frame.maxY + (englishLabel.isHidden ? 0 : 1)
        )
        centerOffset = CGPoint(x: symbol.side / 2 + Self.symbolGap + tagSize.width / 2, y: 0)
    }
}

private enum StationAnnotationStyle {
    /// Above this span an ordinary station is a dot in a smear, so it is not drawn. Interchange
    /// links share it.
    static let ordinaryStationMaxDelta: CLLocationDegrees = 0.1

    static func isVisible(at maxDelta: CLLocationDegrees, isTransfer: Bool, alwaysVisible: Bool) -> Bool {
        alwaysVisible || maxDelta <= (isTransfer ? 0.8 : ordinaryStationMaxDelta)
    }

    static func labelSize(at maxDelta: CLLocationDegrees) -> CGFloat {
        maxDelta <= 0.055 ? 12 : (maxDelta <= 0.18 ? 10 : 9)
    }
}

extension MapVisibleRegion {
    var mkCoordinateRegion: MKCoordinateRegion {
        MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(
                latitudeDelta: latitudeDelta,
                longitudeDelta: longitudeDelta
            )
        )
    }

    var signature: String {
        [
            center.latitude,
            center.longitude,
            latitudeDelta,
            longitudeDelta
        ]
        .map { String(format: "%.6f", $0) }
        .joined(separator: ",")
    }
}

/// An `MKMapView` that knows how much of itself the app draws over.
///
/// `setRegion` centres a coordinate in the view's **layout margins**, by default the system safe
/// area, not its bounds (measured: raising `layoutMargins.top` by 300 moved the centred rider to
/// the middle of the remaining band). This map is full-bleed under chrome the system does not know
/// about, a search pill and attribution row over its top ~120 points, so the safe-area band would
/// centre the rider under the search bar.
///
/// The tab bar is already in `safeAreaInsets`, but on a foldable it can arrive on the trailing
/// edge; `applyLayoutMargins` adds all four edges separately for that reason.
private final class ChromeInsetMapView: MKMapView {
    /// Added to the safe area, not replacing it.
    var chromeInsets: UIEdgeInsets = .zero {
        didSet {
            guard chromeInsets != oldValue else { return }
            applyLayoutMargins()
        }
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        applyLayoutMargins()
    }

    private func applyLayoutMargins() {
        // Takes the safe area over by hand: `layoutMargins` is otherwise recomputed from it and
        // would lose the chrome on the next layout pass.
        insetsLayoutMarginsFromSafeArea = false
        let safeArea = safeAreaInsets
        layoutMargins = UIEdgeInsets(
            top: safeArea.top + chromeInsets.top,
            left: safeArea.left + chromeInsets.left,
            bottom: safeArea.bottom + chromeInsets.bottom,
            right: safeArea.right + chromeInsets.right
        )
    }
}
