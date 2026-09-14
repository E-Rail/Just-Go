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
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
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
    let route: Route?
    let showsUserLocation: Bool
    /// How much of the map's top edge the app's floating chrome covers, measured so Dynamic Type
    /// moves it too. MapKit centres inside the layout margins, so without this a rider is centred
    /// behind the search bar. See `ChromeInsetMapView`.
    var topChromeHeight: CGFloat = 0
    /// How heavily to draw the network's lines: heavier on a page about one line, where the browse
    /// map's weight reads as a hairline.
    var networkLineWidth: CGFloat = 6
    /// Where *MapKit* draws the rider, in the map's GCJ-02 frame, which is not always what Core
    /// Location said (~540 m off in Beijing on a device reporting WGS-84). See
    /// `LocationService.mapSpaceCorrection`.
    var onUserLocationChanged: ((CLLocationCoordinate2D) -> Void)?
    let onRegionChanged: ((MapVisibleRegion) -> Void)?
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
        mapView.chromeInsets = UIEdgeInsets(top: topChromeHeight, left: 0, bottom: 0, right: 0)
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
        context.coordinator.sync(parent: self, on: mapView)
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        (mapView as? ChromeInsetMapView)?.chromeInsets = UIEdgeInsets(
            top: topChromeHeight, left: 0, bottom: 0, right: 0
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
        private var markerVisibilityBand = -1
        /// Drives `strokeScale`. Seeded wide so a new map's first stroke suits the zoom it is
        /// actually at.
        private var currentMaxDelta: CLLocationDegrees = 0.05
        private var annotationStations: [ObjectIdentifier: Station] = [:]
        private var stationAnnotationsByID: [String: StationAnnotation] = [:]
        private var overlayColors: [ObjectIdentifier: UIColor] = [:]
        private var overlayWidths: [ObjectIdentifier: CGFloat] = [:]
        private var overlayDashes: [ObjectIdentifier: [CGFloat]] = [:]
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
            syncStations(on: mapView)
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
            networkOverlays = []
            interchangeOverlays = []

            addNetworks(parent.metroNetworks)
            addInterchanges(across: parent.metroNetworks)
            if !networkOverlays.isEmpty {
                mapView.addOverlays(networkOverlays, level: .aboveRoads)
            }
            syncInterchangeVisibility(on: mapView)
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
                    colorHex: SegmentType.transfer.colorHex(line: nil),
                    lineWidth: 5,
                    dashPattern: SegmentType.transfer.dash(width: 5),
                    simplify: false,
                    collection: &interchangeOverlays
                )
            }
        }

        private func addRoute(_ route: Route) {
            for segment in route.segments {
                let coordinates = segment.drawableCoordinates.map {
                    CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                }
                guard coordinates.count >= 2 else { continue }
                let width: CGFloat = segment.type.isAccessLeg ? 7 : 6
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
                addStationConnectors(for: segment, drawn: coordinates)
            }
        }

        /// Joins a ride's drawn track to the stations it calls at, in the transfer grey and dash,
        /// never the line's colour. A station node can sit hundreds of metres from its rail (顺义 is
        /// 272 m from 15号线's track). The ride draws only the track; bending it out to the platform
        /// would spike, and leaving the gap looks broken. Colour means "the train runs here", and
        /// this is not track.
        private func addStationConnectors(for segment: RouteSegment, drawn: [CLLocationCoordinate2D]) {
            guard segment.type.isTransit,
                  let first = segment.stationStops.first?.coordinate,
                  let last = segment.stationStops.last?.coordinate,
                  let trackStart = drawn.first,
                  let trackEnd = drawn.last else { return }
            let boarding = CLLocationCoordinate2D(latitude: first.latitude, longitude: first.longitude)
            let alighting = CLLocationCoordinate2D(latitude: last.latitude, longitude: last.longitude)
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
                refreshMarkerVisibility(on: mapView)
                syncInterchangeVisibility(on: mapView)
                // Safe on the marker band: its breakpoints (0.055, 0.1, 0.18, 0.8) include
                // `strokeScale`'s (0.055, 0.18, 0.8). Keep that true if either set moves.
                refreshOverlayWidths(on: mapView)
            }
            parent.onRegionChanged?(visibleRegion)
        }

        /// How much to shrink every stroke at the current zoom. `MKPolylineRenderer.lineWidth` is
        /// in screen points, so zoomed out to a whole trip a walk's round dots merge into one blob.
        /// The dash pattern scales by the same factor to keep its rhythm.
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
            renderer.lineDashPattern = overlayDashes[key]?.map { NSNumber(value: Double(max(0.1, $0 * scale))) }
        }

        /// Re-strokes overlays already on screen: MapKit hands back its existing renderers, so this
        /// sets two numbers each and redraws.
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
            // Breakpoints: `StationAnnotationStyle`'s size buckets (0.055, 0.18) and visibility
            // thresholds (ordinary ≤ 0.1, transfer ≤ 0.8).
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
    // Resolved once (zh-Hant involves a Hans→Hant transform); MapKit reads title and subtitle
    // repeatedly.
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
        tagView.layer.borderWidth = 0.5
        applyBorderColor()
        // `UIView.backgroundColor` re-resolves with the appearance; a `.cgColor` is resolved once
        // and frozen, so it is refreshed here when the in-app Light/Dark setting changes.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: StationAnnotationView, _) in
            view.applyBorderColor()
        }
        addSubview(symbolView)
        addSubview(tagView)
        tagView.addSubview(chineseLabel)
        tagView.addSubview(englishLabel)
    }

    private func applyBorderColor() {
        tagView.layer.borderColor = UIColor.separator.resolvedColor(with: traitCollection).cgColor
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
    /// Above this span an ordinary station is a dot in a smear, so it is not drawn. Interchange
    /// links share it.
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
