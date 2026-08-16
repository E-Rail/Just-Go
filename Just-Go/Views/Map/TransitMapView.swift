import MapKit
import SwiftUI

struct MetroGeometryAttributionView: View {
    var body: some View {
        Link(destination: URL(string: "https://www.openstreetmap.org/copyright")!) {
            Text(AppLocalization.localized("Metro geometry © OpenStreetMap contributors"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(AppLocalization.localized("Metro geometry © OpenStreetMap contributors"))
    }
}

struct TransitMapView: UIViewRepresentable {
    @Binding var visibleRegion: MapVisibleRegion?
    let stations: [Station]
    /// Draws every supplied station regardless of zoom. The browse map hides non-transfer
    /// stations above a 0.1° span, because a city's worth of them at that scale is a smear — but a
    /// route map is handed only the ~30 stops the trip actually calls at, and hiding those is
    /// hiding the answer. Whole-trip spans are wider than 0.1° almost by definition, which is why
    /// the route map drew a line through an empty city.
    var alwaysShowsStations = false
    let metroNetworks: [MetroNetwork]
    let route: Route?
    let showsUserLocation: Bool
    /// Where *MapKit* thinks the rider is, which is not always what Core Location said.
    ///
    /// Everything this app draws and measures against is GCJ-02 (`coordinateSystem` in every
    /// bundled network, and Apple's basemap across Greater China). A `CLLocation` is the one input
    /// that nothing converts — so on a device that reports WGS-84 the rider's own position is the
    /// only coordinate in the app in the wrong frame, ~540 m out in Beijing. This is the map's
    /// answer, in the map's frame, by definition: see `LocationService.mapSpaceCorrection`.
    var onUserLocationChanged: ((CLLocationCoordinate2D) -> Void)?
    let onRegionChanged: ((MapVisibleRegion) -> Void)?
    let onStationSelected: (Station) -> Void
    // Two-phase POI tap: `onPlaceTapped` fires synchronously with the feature's name +
    // coordinate so the UI can react instantly; `onPlaceResolved` fires later once the
    // (slow, server-side) MKMapItemRequest has produced the full place card item.
    var onPlaceTapped: ((_ name: String?, _ coordinate: CLLocationCoordinate2D) -> Void)?
    var onPlaceResolved: ((MKMapItem) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        mapView.delegate = context.coordinator
        mapView.showsCompass = true
        mapView.showsScale = true
        mapView.pointOfInterestFilter = .includingAll
        mapView.selectableMapFeatures = [.pointsOfInterest]
        mapView.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .flat)
        context.coordinator.sync(parent: self, on: mapView)
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        context.coordinator.sync(parent: self, on: mapView)
    }

    static func dismantleUIView(_ mapView: MKMapView, coordinator: Coordinator) {
        coordinator.cancelPOIResolution()
        mapView.delegate = nil
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        private var parent: TransitMapView
        private var regionSignature = ""
        private var networkSignature = ""
        private var stationSignature = ""
        private var routeSignature = ""
        private var markerVisibilityBand = -1
        /// Drives `strokeScale`. Seeded wide so the first stroke of a freshly-built map is sized
        /// for the zoom it is actually at, rather than for a street-level view it may never show.
        private var currentMaxDelta: CLLocationDegrees = 0.05
        private var annotationStations: [ObjectIdentifier: Station] = [:]
        private var stationAnnotationsByID: [String: StationAnnotation] = [:]
        private var overlayColors: [ObjectIdentifier: UIColor] = [:]
        private var overlayWidths: [ObjectIdentifier: CGFloat] = [:]
        private var overlayDashes: [ObjectIdentifier: [NSNumber]] = [:]
        private var networkOverlays: [MKOverlay] = []
        /// Held apart from the rest of the network because these come and go with zoom.
        private var interchangeOverlays: [MKOverlay] = []
        private var routeOverlays: [MKOverlay] = []
        private var stationSymbolImages: [String: UIImage] = [:]
        private var poiTask: Task<Void, Never>?

        init(parent: TransitMapView) {
            self.parent = parent
        }

        deinit {
            poiTask?.cancel()
        }

        func cancelPOIResolution() {
            poiTask?.cancel()
            poiTask = nil
        }

        func sync(parent: TransitMapView, on mapView: MKMapView) {
            self.parent = parent
            mapView.showsUserLocation = parent.showsUserLocation
            #if DEBUG
            MainThreadHangMonitor.measure("map.syncRegion") { syncRegion(on: mapView) }
            MainThreadHangMonitor.measure("map.syncNetworks") { syncNetworks(on: mapView) }
            MainThreadHangMonitor.measure("map.syncStations") { syncStations(on: mapView) }
            MainThreadHangMonitor.measure("map.syncRoute") { syncRoute(on: mapView) }
            #else
            syncRegion(on: mapView)
            syncNetworks(on: mapView)
            syncStations(on: mapView)
            syncRoute(on: mapView)
            #endif
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
            networkOverlays = []
            interchangeOverlays = []

            addNetworks(parent.metroNetworks)
            addInterchanges(across: parent.metroNetworks)
            if !networkOverlays.isEmpty {
                mapView.addOverlays(networkOverlays, level: .aboveRoads)
            }
            syncInterchangeVisibility(on: mapView)
        }

        /// Interchange links are drawn exactly while the stations they join are.
        ///
        /// They were drawn at every zoom, and 广安门内 ↔ 牛街 is 498 m: viewed across a whole city
        /// that is a grey lozenge a few points long, sitting on a map where neither of its two
        /// endpoints is drawn at all. A link is an instruction to walk somewhere, and it can only
        /// mean something when the rider can see both ends of the walk — which is the same
        /// threshold `StationAnnotationStyle` already uses for an ordinary station.
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

        private func syncStations(on mapView: MKMapView) {
            // O(1)-ish change check via a hash of the desired station IDs, instead of building a
            // multi-KB joined string on every SwiftUI invalidation.
            var hasher = Hasher()
            hasher.combine(parent.stations.count)
            for station in parent.stations { hasher.combine(station.stationID) }
            let nextSignature = String(hasher.finalize())
            guard nextSignature != stationSignature else { return }
            stationSignature = nextSignature

            let desiredByID = Dictionary(parent.stations.map { ($0.stationID, $0) }, uniquingKeysWith: { first, _ in first })
            let desiredIDs = Set(desiredByID.keys)
            let currentIDs = Set(stationAnnotationsByID.keys)

            // Remove only the annotations that are gone; keep (and preserve the dequeued views of)
            // the ones that remain, instead of clearing and re-adding everything.
            let removedIDs = currentIDs.subtracting(desiredIDs)
            if !removedIDs.isEmpty {
                let removed = removedIDs.compactMap { stationAnnotationsByID.removeValue(forKey: $0) }
                for annotation in removed { annotationStations.removeValue(forKey: ObjectIdentifier(annotation)) }
                mapView.removeAnnotations(removed)
            }

            let addedIDs = desiredIDs.subtracting(currentIDs)
            if !addedIDs.isEmpty {
                let added = addedIDs.compactMap { desiredByID[$0] }.map { station -> StationAnnotation in
                    let annotation = StationAnnotation(station: station)
                    annotationStations[ObjectIdentifier(annotation)] = station
                    stationAnnotationsByID[station.stationID] = annotation
                    return annotation
                }
                mapView.addAnnotations(added)
            }
        }

        private func syncRoute(on mapView: MKMapView) {
            let nextSignature = parent.route?.id.uuidString ?? "no-route"
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

        /// Every loaded pack's lines, with each stretch of track drawn once.
        ///
        /// Adjacent cities each ship the intercity corridors they share, byte for byte — 234 paths
        /// across the Guangzhou / Foshan / Dongguan packs, 130 of them distinct. Drawn per pack,
        /// the shared corridors were laid down two and three times over. Identity is the path's own
        /// points, so this can only ever collapse a way onto a copy of itself; it is the drawing
        /// half of the same rule `canonicalStationIDs` and `canonicalLineIDs` apply to the graph.
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
                            lineWidth: 4,
                            simplify: false,
                            collection: &networkOverlays
                        )
                    }
                }
            }
        }

        /// The links between two stations riders treat as one interchange.
        ///
        /// Drawn on the network, not only inside a planned route: the rider needs to see that
        /// 广安门内 and 牛街 are connected *before* deciding to plan through them. Solid when the
        /// walk stays inside the building, dashed when it goes out to the street.
        ///
        /// Resolved across every loaded network rather than within each one, because a link's two
        /// halves can live in different packs — Shenzhen's 罗湖 and Hong Kong's 羅湖 are one
        /// crossing in two networks, and neither pack can draw it alone.
        private func addInterchanges(across networks: [MetroNetwork]) {
            var coordinatesByID: [String: CLLocationCoordinate2D] = [:]
            for network in networks {
                for station in network.stations where coordinatesByID[station.id] == nil {
                    coordinatesByID[station.id] = station.coordinate
                }
            }
            // A cross-pack link is written into both of its packs, so it arrives twice.
            var drawn = Set<String>()
            for link in networks.flatMap(\.interchanges) {
                guard drawn.insert("\(link.fromStationID)|\(link.toStationID)").inserted,
                      let from = coordinatesByID[link.fromStationID],
                      let to = coordinatesByID[link.toStationID] else { continue }
                addPolyline(
                    [from, to],
                    colorHex: "#8E8E93",
                    lineWidth: 5,
                    dashPattern: Self.transferDashPattern,
                    simplify: false,
                    collection: &interchangeOverlays
                )
            }
        }

        /// A dash means "you change here", everywhere, on both maps.
        ///
        /// This used to be dashed only for a change that leaves the paid area and solid for one
        /// inside the station. Two marks for one idea is a legend the rider has to learn, and the
        /// difference between them is already stated in words on the leg — "leave the station and
        /// walk to X" versus "connected inside the station" — where it cannot be misread. One mark
        /// for every change, and the words carry the distinction.
        static let transferDashPattern: [NSNumber] = [2, 6]

        private func addRoute(_ route: Route) {
            for segment in route.segments {
                let coordinates = segment.drawableCoordinates.map {
                    CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                }
                guard coordinates.count >= 2 else { continue }
                let isAccessLeg = segment.type.isAccessLeg
                // Round dots, the convention every map app uses for a leg on foot, and the thing
                // that makes a walk legible at all: solid grey at this width is the same mark the
                // basemap draws roads with, so a walking-only route read as no route. A bike leg
                // gets a longer dash — near enough to read as the same family of "you cover this
                // yourself", far enough apart to tell at a glance. A drive is solid: it is a road
                // route, and it earns its own colour below rather than a grey the basemap owns.
                let dashPattern: [NSNumber]?
                switch segment.type {
                case .walking: dashPattern = Self.selfPoweredDashPattern
                case .transfer: dashPattern = Self.transferDashPattern
                case .cycling: dashPattern = [7, 6]
                case .driving: dashPattern = nil
                case .subway: dashPattern = nil
                }
                // A casing under every ride, because a line's colour is data and some of it is
                // grey. The Pearl River Delta intercity services publish no colour in OSM, so the
                // importer's fallback gives them #8E8E93 — the same grey the basemap draws roads
                // with, which made a real leg of a real route look like nothing was drawn at all.
                // Widening and darkening what sits underneath fixes it for every line at once,
                // rather than inventing a colour for the ones that don't state theirs. Solid legs
                // only: a casing behind a dashed one fills the gaps back in.
                if dashPattern == nil {
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
                    colorHex: routeColorHex(for: segment),
                    lineWidth: isAccessLeg ? 7 : 6,
                    dashPattern: dashPattern,
                    simplify: true,
                    collection: &routeOverlays
                )
                addStationConnectors(for: segment, drawn: coordinates)
            }
        }

        /// Joins a ride's drawn track back to the stations it calls at — in grey dots, never in
        /// the line's colour.
        ///
        /// A station node can sit a few hundred metres from the rail that serves it (顺义 is 272 m
        /// from 15号线's track and 366 m from 市郊铁路通密线's; 339 of 8,108 station-on-line pairs
        /// across the bundled networks are more than 60 m off). The ride itself draws the track and
        /// only the track, because that is where the train goes — bending the coloured line out to
        /// the platform and back drew a right-angled spike per station, which is what made a trip
        /// through 顺义 look like a rectangle bolted to the route.
        ///
        /// But leaving the gap open read as a broken route. So the gap is drawn as what it
        /// actually is: the bit the rider covers themselves, getting between the entrance and the
        /// platform. Same grey, same round dots as a walk, because it is the same kind of thing —
        /// colour on this map means "the train runs here", and this is not track.
        private func addStationConnectors(for segment: RouteSegment, drawn: [CLLocationCoordinate2D]) {
            guard segment.type.isTransit,
                  let first = segment.stationStops.first?.coordinate,
                  let last = segment.stationStops.last?.coordinate,
                  let trackStart = drawn.first,
                  let trackEnd = drawn.last else { return }
            let boarding = CLLocationCoordinate2D(latitude: first.latitude, longitude: first.longitude)
            let alighting = CLLocationCoordinate2D(latitude: last.latitude, longitude: last.longitude)
            for (station, track) in [(boarding, trackStart), (alighting, trackEnd)] {
                // Below this the two are the same place at any zoom the rider can reach, and a
                // two-point overlay per station per leg is not free.
                guard station.distance(to: track) >= 15 else { continue }
                addPolyline(
                    [station, track],
                    colorHex: Self.selfPoweredColorHex,
                    lineWidth: 7,
                    // Dashed, like every other change: this stub is the rider getting between the
                    // station and the platform the train actually stops at, which is part of the
                    // same movement, not a street walk.
                    dashPattern: Self.transferDashPattern,
                    simplify: false,
                    collection: &routeOverlays
                )
            }
        }

        /// Grey round dots: every part of a trip the rider covers under their own power — the walk
        /// at each end, the change between platforms, and the hop between a station and the track
        /// that serves it. One colour and one pattern for all of them, so the map has exactly two
        /// vocabularies: coloured means a train carries you, grey means you move yourself.
        static let selfPoweredColorHex = "#8E8E93"
        static let selfPoweredDashPattern: [NSNumber] = [0.1, 11]

        private func routeColorHex(for segment: RouteSegment) -> String {
            switch segment.type {
            case .walking:
                return Self.selfPoweredColorHex
            case .cycling:
                return "#34C759"
            // Not grey. A drive is drawn solid, and solid grey at this width is indistinguishable
            // from the roads underneath it — the same trap the walking dots exist to avoid.
            case .driving:
                return "#5856D6"
            case .subway:
                return segment.lineColorHex ?? "#007AFF"
            // Grey, not the orange it used to be. A change is the rider walking between two
            // platforms — the same thing as the walk at either end of the trip and the hop from a
            // platform to its track, so it gets the same mark. Orange read as a third mode of
            // travel on a map whose colours otherwise mean "which line".
            case .transfer:
                return Self.selfPoweredColorHex
            }
        }

        // Builds the polyline and records it for a single batched `addOverlays(_:level:)` call
        // by the caller (`addNetwork`/`addRoute`) once their loop finishes — adding overlays
        // one at a time triggers MapKit's per-insertion layout/renderer bookkeeping for every
        // line segment, which is a visible hitch the first time a large city (e.g. Beijing's
        // 33 lines) syncs.
        private func addPolyline(
            _ coordinates: [CLLocationCoordinate2D],
            colorHex: String,
            lineWidth: CGFloat,
            dashPattern: [NSNumber]? = nil,
            alpha: CGFloat = 1,
            simplify: Bool,
            collection: inout [MKOverlay]
        ) {
            let displayCoordinates = simplify ? simplifiedCoordinates(coordinates) : coordinates
            let polyline = MKPolyline(coordinates: displayCoordinates, count: displayCoordinates.count)
            overlayColors[ObjectIdentifier(polyline)] = UIColor(Color(hex: colorHex)).withAlphaComponent(alpha)
            overlayWidths[ObjectIdentifier(polyline)] = lineWidth
            overlayDashes[ObjectIdentifier(polyline)] = dashPattern
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
            guard let stationAnnotation = annotation as? StationAnnotation else { return nil }

            let identifier = "station"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? StationAnnotationView ??
                StationAnnotationView(annotation: stationAnnotation, reuseIdentifier: identifier)
            view.annotation = stationAnnotation
            configureStationSymbol(view, station: stationAnnotation.station, region: mapView.region)
            return view
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let annotation = view.annotation else { return }
            if let station = annotationStations[ObjectIdentifier(annotation)] {
                // A station tap supersedes any in-flight POI resolve — stop the request
                // instead of letting it run to completion for a result nobody will show.
                cancelPOIResolution()
                parent.onStationSelected(station)
                mapView.deselectAnnotation(annotation, animated: false)
            } else if let feature = annotation as? MKMapFeatureAnnotation,
                      feature.featureType == .pointOfInterest {
                // Surface the tap immediately from the feature's synchronous title/coordinate so
                // the UI can present (or open a station) without waiting on the network resolve.
                parent.onPlaceTapped?(feature.title, feature.coordinate)
                // Resolve the tapped Apple POI to a full MKMapItem in the background, then surface
                // it. Deselect only after the async resolve so the feature stays valid.
                poiTask?.cancel()
                poiTask = Task { @MainActor [weak self, weak mapView] in
                    let mapItem = try? await MKMapItemRequest(mapFeatureAnnotation: feature).mapItem
                    mapView?.deselectAnnotation(feature, animated: false)
                    // MKMapItemRequest, like MKLocalSearch, ignores task cancellation — so guard
                    // explicitly to avoid a superseded tap firing onPlaceResolved with a stale
                    // item; weak self prevents the cancelled task from retaining the Coordinator.
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
            // Marker size/visibility only changes when maxDelta crosses one of the style or
            // visibility thresholds; within a band every annotation reconfigures identically, so
            // skip the O(N) sweep while panning at a fixed zoom.
            let maxDelta = max(region.span.latitudeDelta, region.span.longitudeDelta)
            let band = markerBand(for: maxDelta)
            if band != markerVisibilityBand {
                markerVisibilityBand = band
                currentMaxDelta = maxDelta
                refreshMarkerVisibility(on: mapView)
                syncInterchangeVisibility(on: mapView)
                // Safe to hang off the marker band: its breakpoints (0.055, 0.1, 0.18, 0.8) are a
                // superset of strokeScale's (0.055, 0.18, 0.8), so no stroke change can happen
                // without a band change. Keep that true if either set moves.
                refreshOverlayWidths(on: mapView)
            }
            parent.onRegionChanged?(visibleRegion)
        }

        /// How much to shrink every stroke at the current zoom, and why there has to be a factor
        /// at all.
        ///
        /// `MKPolylineRenderer.lineWidth` is in screen points, so it does not change as the map
        /// zooms — a 7pt line is 7pt whether it spans a street or a province. Zoom out to fit a
        /// whole trip and the route collapses toward a point while its stroke stays put, so the
        /// round dots of a walk stop reading as a dotted line and merge into one fat grey blob.
        /// The dash pattern is scaled by the same factor so the dot-to-gap rhythm is preserved
        /// rather than turning into sparse specks.
        private func strokeScale(for maxDelta: CLLocationDegrees) -> CGFloat {
            switch maxDelta {
            case ..<0.055: return 1
            case ..<0.18: return 0.85
            case ..<0.8: return 0.62
            default: return 0.45
            }
        }

        private func applyStrokeWidth(to renderer: MKPolylineRenderer, polyline: MKPolyline) {
            let key = ObjectIdentifier(polyline)
            let scale = strokeScale(for: currentMaxDelta)
            // Floored so a hairline never disappears entirely at the widest zooms.
            renderer.lineWidth = max(1.5, (overlayWidths[key] ?? 5) * scale)
            renderer.lineDashPattern = overlayDashes[key]?.map {
                NSNumber(value: max(0.1, $0.doubleValue * Double(scale)))
            }
        }

        /// Re-strokes the overlays already on screen. Cheap: MapKit hands back the renderer it
        /// already made, so this touches two numbers per overlay and asks for a redraw.
        private func refreshOverlayWidths(on mapView: MKMapView) {
            for overlay in mapView.overlays {
                guard let polyline = overlay as? MKPolyline,
                      let renderer = mapView.renderer(for: overlay) as? MKPolylineRenderer else {
                    continue
                }
                applyStrokeWidth(to: renderer, polyline: polyline)
                renderer.setNeedsDisplay()
            }
        }

        private func markerBand(for maxDelta: CLLocationDegrees) -> Int {
            // Breakpoints = union of StationAnnotationStyle size buckets (0.055, 0.18) and the
            // visibility thresholds (normal ≤ 0.1, transfer ≤ 0.8).
            if maxDelta <= 0.055 { return 0 }
            if maxDelta <= 0.1 { return 1 }
            if maxDelta <= 0.18 { return 2 }
            if maxDelta <= 0.8 { return 3 }
            return 4
        }

        private func refreshMarkerVisibility(on mapView: MKMapView) {
            for annotation in mapView.annotations {
                guard let stationAnnotation = annotation as? StationAnnotation,
                      let view = mapView.view(for: annotation) else {
                    continue
                }
                configureStationSymbol(view, station: stationAnnotation.station, region: mapView.region)
            }
        }

        private func configureStationSymbol(
            _ view: MKAnnotationView,
            station: Station,
            region: MKCoordinateRegion
        ) {
            guard let view = view as? StationAnnotationView else { return }
            view.canShowCallout = false
            view.displayPriority = station.isTransferStation ? .required : .defaultLow
            view.collisionMode = .rectangle
            let style = StationAnnotationStyle(
                region: region,
                isTransfer: station.isTransferStation,
                alwaysVisible: parent.alwaysShowsStations
            )
            guard style.isVisible else {
                view.isHidden = true
                return
            }

            view.configure(
                station: station,
                style: style,
                symbol: stationSymbolImage(isTransfer: station.isTransferStation, pointSize: style.symbolSize)
            )
            view.isHidden = false
        }

        private func stationSymbolImage(isTransfer: Bool, pointSize: CGFloat) -> UIImage {
            let key = "\(isTransfer)-\(pointSize)"
            if let cached = stationSymbolImages[key] {
                return cached
            }

            let size = CGSize(width: pointSize, height: pointSize)
            let image = UIGraphicsImageRenderer(size: size).image { context in
                let rect = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
                context.cgContext.setFillColor(UIColor.white.cgColor)
                context.cgContext.fillEllipse(in: rect)
                context.cgContext.setStrokeColor(UIColor.black.cgColor)
                context.cgContext.setLineWidth(max(1.5, pointSize * 0.13))
                context.cgContext.strokeEllipse(in: rect)

                guard isTransfer,
                      let transfer = UIImage(
                        systemName: "arrow.triangle.2.circlepath",
                        withConfiguration: UIImage.SymbolConfiguration(
                            pointSize: pointSize * 0.52,
                            weight: .bold
                        )
                      )?.withTintColor(.black, renderingMode: .alwaysOriginal) else {
                    return
                }
                transfer.draw(at: CGPoint(
                    x: (pointSize - transfer.size.width) / 2,
                    y: (pointSize - transfer.size.height) / 2
                ))
            }
            stationSymbolImages[key] = image
            return image
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let polyline = overlay as? MKPolyline else {
                return MKOverlayRenderer(overlay: overlay)
            }

            let renderer = MKPolylineRenderer(polyline: polyline)
            renderer.strokeColor = overlayColors[ObjectIdentifier(polyline)] ?? .systemBlue
            applyStrokeWidth(to: renderer, polyline: polyline)
            renderer.lineCap = .round
            renderer.lineJoin = .round
            return renderer
        }
    }
}

private final class StationAnnotation: NSObject, MKAnnotation {
    let station: Station
    // Localized strings resolved once at creation (each involves a Hans→Hant StringTransform in
    // zh-Hant); MapKit reads title/subtitle repeatedly for accessibility and search.
    let title: String?
    let subtitle: String?

    var coordinate: CLLocationCoordinate2D {
        station.coordinate
    }

    init(station: Station) {
        self.station = station
        self.title = station.localizedName
        self.subtitle = station.uniqueLogicalLines.map(\.localizedName).joined(separator: " / ")
        super.init()
    }
}

private final class StationAnnotationView: MKAnnotationView {
    private let symbolView = UIImageView()
    private let tagView = UIView()
    private let chineseLabel = UILabel()
    private let englishLabel = UILabel()
    private var configurationKey = ""

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)

        tagView.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.9)
        tagView.layer.borderColor = UIColor.separator.cgColor
        tagView.layer.borderWidth = 0.5
        addSubview(symbolView)
        addSubview(tagView)
        tagView.addSubview(chineseLabel)
        tagView.addSubview(englishLabel)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func configure(station: Station, style: StationAnnotationStyle, symbol: UIImage) {
        let nextKey = "\(station.stationID):\(style.id)"
        guard nextKey != configurationKey else { return }
        configurationKey = nextKey

        let symbolSize = style.symbolSize
        let labelSize = style.labelSize
        symbolView.image = symbol
        symbolView.frame = CGRect(x: 0, y: 0, width: symbolSize, height: symbolSize)

        chineseLabel.text = station.localizedName
        chineseLabel.font = .systemFont(ofSize: labelSize, weight: .semibold)
        chineseLabel.textColor = .label
        chineseLabel.sizeToFit()

        englishLabel.text = station.alternateLocalizedName
        englishLabel.font = .systemFont(ofSize: max(7, labelSize - 3), weight: .regular)
        englishLabel.textColor = .secondaryLabel
        englishLabel.isHidden = englishLabel.text?.isEmpty != false
        englishLabel.sizeToFit()

        let horizontalPadding: CGFloat = 6
        let verticalPadding: CGFloat = 3
        let labelWidth = max(chineseLabel.bounds.width, englishLabel.isHidden ? 0 : englishLabel.bounds.width)
        let labelHeight = chineseLabel.bounds.height + (englishLabel.isHidden ? 0 : englishLabel.bounds.height + 1)
        let tagSize = CGSize(width: labelWidth + horizontalPadding * 2, height: labelHeight + verticalPadding * 2)
        let viewHeight = max(symbolSize, tagSize.height)
        let tagOrigin = CGPoint(x: symbolSize + 4, y: (viewHeight - tagSize.height) / 2)

        bounds = CGRect(x: 0, y: 0, width: symbolSize + 4 + tagSize.width, height: viewHeight)
        symbolView.center = CGPoint(x: symbolSize / 2, y: viewHeight / 2)
        tagView.frame = CGRect(origin: tagOrigin, size: tagSize)
        tagView.layer.cornerRadius = min(8, tagSize.height / 2)
        chineseLabel.frame.origin = CGPoint(x: horizontalPadding, y: verticalPadding)
        englishLabel.frame.origin = CGPoint(
            x: horizontalPadding,
            y: chineseLabel.frame.maxY + (englishLabel.isHidden ? 0 : 1)
        )
        centerOffset = CGPoint(x: bounds.width / 2 - symbolSize / 2, y: 0)
        accessibilityLabel = station.accessibilityLabel
    }
}

private struct StationAnnotationStyle {
    /// Above this span an ordinary station is a dot in a smear of dots, so it is not drawn. Shared
    /// with the interchange links, which join two ordinary stations and mean nothing without them.
    static let ordinaryStationMaxDelta: CLLocationDegrees = 0.1

    let isVisible: Bool
    let symbolSize: CGFloat
    let labelSize: CGFloat
    let id: String

    init(region: MKCoordinateRegion, isTransfer: Bool, alwaysVisible: Bool = false) {
        let maxDelta = max(region.span.latitudeDelta, region.span.longitudeDelta)
        isVisible = alwaysVisible || maxDelta <= (isTransfer ? 0.8 : Self.ordinaryStationMaxDelta)
        let bucket = maxDelta <= 0.055 ? 0 : (maxDelta <= 0.18 ? 1 : 2)
        let baseSize: CGFloat = bucket == 0 ? 18 : (bucket == 1 ? 9 : 6)
        symbolSize = baseSize + (isTransfer ? 3 : 0)
        labelSize = bucket == 0 ? 12 : (bucket == 1 ? 10 : 9)
        id = "\(isTransfer)-\(bucket)"
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
