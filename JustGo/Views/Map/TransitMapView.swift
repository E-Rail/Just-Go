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
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
        private var annotationStations: [ObjectIdentifier: Station] = [:]
        private var stationAnnotationsByID: [String: StationAnnotation] = [:]
        private var overlayColors: [ObjectIdentifier: UIColor] = [:]
        private var overlayWidths: [ObjectIdentifier: CGFloat] = [:]
        private var overlayDashes: [ObjectIdentifier: [NSNumber]] = [:]
        private var networkOverlays: [MKOverlay] = []
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
            clearOverlayMetadata(networkOverlays)
            networkOverlays = []

            for network in parent.metroNetworks {
                addNetwork(network)
            }
            if !networkOverlays.isEmpty {
                mapView.addOverlays(networkOverlays, level: .aboveRoads)
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

        private func addNetwork(_ network: MetroNetwork) {
            for line in network.lines {
                for path in line.paths where path.count >= 2 {
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

        private func addRoute(_ route: Route) {
            for segment in route.segments {
                let polylineCoordinates = segment.polylineCoordinates.map {
                    CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                }
                let coordinates = polylineCoordinates.count >= 2
                    ? polylineCoordinates
                    : segment.stationStops.compactMap(\.coordinate).map {
                        CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                    }
                guard coordinates.count >= 2 else { continue }
                let isWalking = segment.type == .walking
                addPolyline(
                    coordinates,
                    colorHex: routeColorHex(for: segment),
                    lineWidth: isWalking ? 7 : 6,
                    // Round dots, the convention every map app uses for a leg on foot, and the
                    // thing that makes a walk legible at all: solid grey at this width is the same
                    // mark the basemap draws roads with, so a walking-only route read as no route.
                    dashPattern: isWalking ? [0.1, 11] : nil,
                    simplify: true,
                    collection: &routeOverlays
                )
            }
        }

        private func routeColorHex(for segment: RouteSegment) -> String {
            switch segment.type {
            case .walking:
                return "#8E8E93"
            case .subway:
                return segment.lineColorHex ?? "#007AFF"
            case .transfer:
                return "#FF9500"
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
            simplify: Bool,
            collection: inout [MKOverlay]
        ) {
            let displayCoordinates = simplify ? simplifiedCoordinates(coordinates) : coordinates
            let polyline = MKPolyline(coordinates: displayCoordinates, count: displayCoordinates.count)
            overlayColors[ObjectIdentifier(polyline)] = UIColor(Color(hex: colorHex))
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
            let band = markerBand(for: max(region.span.latitudeDelta, region.span.longitudeDelta))
            if band != markerVisibilityBand {
                markerVisibilityBand = band
                refreshMarkerVisibility(on: mapView)
            }
            parent.onRegionChanged?(visibleRegion)
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
            renderer.lineWidth = overlayWidths[ObjectIdentifier(polyline)] ?? 5
            renderer.lineDashPattern = overlayDashes[ObjectIdentifier(polyline)] ?? nil
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
    let isVisible: Bool
    let symbolSize: CGFloat
    let labelSize: CGFloat
    let id: String

    init(region: MKCoordinateRegion, isTransfer: Bool, alwaysVisible: Bool = false) {
        let maxDelta = max(region.span.latitudeDelta, region.span.longitudeDelta)
        isVisible = alwaysVisible || maxDelta <= (isTransfer ? 0.8 : 0.1)
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
