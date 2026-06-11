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
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(AppLocalization.localized("Metro geometry © OpenStreetMap contributors"))
    }
}

struct TransitMapView: UIViewRepresentable {
    @Binding var visibleRegion: MapVisibleRegion?
    let stations: [Station]
    let metroNetworks: [MetroNetwork]
    let route: Route?
    let showsUserLocation: Bool
    let onRegionChanged: ((MapVisibleRegion) -> Void)?
    let onStationSelected: (Station) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = showsUserLocation
        mapView.showsCompass = true
        mapView.showsScale = true
        mapView.pointOfInterestFilter = .includingAll
        mapView.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .flat)
        context.coordinator.sync(parent: self, on: mapView)
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        context.coordinator.sync(parent: self, on: mapView)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        private var parent: TransitMapView
        private var regionSignature = ""
        private var networkSignature = ""
        private var stationSignature = ""
        private var routeSignature = ""
        private var annotationStations: [ObjectIdentifier: Station] = [:]
        private var overlayColors: [ObjectIdentifier: UIColor] = [:]
        private var overlayWidths: [ObjectIdentifier: CGFloat] = [:]
        private var networkOverlays: [MKOverlay] = []
        private var routeOverlays: [MKOverlay] = []
        private var stationSymbolImages: [String: UIImage] = [:]

        init(parent: TransitMapView) {
            self.parent = parent
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
            mapView.setRegion(visibleRegion.mkCoordinateRegion, animated: true)
            regionSignature = nextSignature
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
                addNetwork(network, to: mapView)
            }
        }

        private func syncStations(on mapView: MKMapView) {
            let nextSignature = parent.stations.map(\.stationID).joined(separator: ",")
            guard nextSignature != stationSignature else { return }
            stationSignature = nextSignature
            annotationStations.removeAll()
            mapView.removeAnnotations(mapView.annotations.filter { !($0 is MKUserLocation) })

            let annotations = parent.stations.map { station in
                let annotation = StationAnnotation(station: station)
                annotationStations[ObjectIdentifier(annotation)] = station
                return annotation
            }
            mapView.addAnnotations(annotations)
        }

        private func syncRoute(on mapView: MKMapView) {
            let nextSignature = parent.route?.id.uuidString ?? "no-route"
            guard nextSignature != routeSignature else { return }
            routeSignature = nextSignature
            mapView.removeOverlays(routeOverlays)
            clearOverlayMetadata(routeOverlays)
            routeOverlays = []
            if let route = parent.route {
                addRoute(route, to: mapView)
            }
        }

        private func clearOverlayMetadata(_ overlays: [MKOverlay]) {
            for overlay in overlays {
                overlayColors.removeValue(forKey: ObjectIdentifier(overlay))
                overlayWidths.removeValue(forKey: ObjectIdentifier(overlay))
            }
        }

        private func addNetwork(_ network: MetroNetwork, to mapView: MKMapView) {
            for line in network.lines {
                for path in line.paths where path.count >= 2 {
                    addPolyline(
                        path.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) },
                        colorHex: line.colorHex,
                        lineWidth: 4,
                        level: .aboveRoads,
                        simplify: false,
                        collection: &networkOverlays,
                        to: mapView
                    )
                }
            }
        }

        private func addRoute(_ route: Route, to mapView: MKMapView) {
            for segment in route.segments {
                let polylineCoordinates = segment.polylineCoordinates.map {
                    CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                }
                let stopCoordinates = segment.stationStops.compactMap(\.coordinate).map {
                    CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                }
                let coordinates = polylineCoordinates.count >= 2 ? polylineCoordinates : stopCoordinates
                guard coordinates.count >= 2 else { continue }
                addPolyline(
                    coordinates,
                    colorHex: routeColorHex(for: segment),
                    lineWidth: 6,
                    level: .aboveLabels,
                    simplify: true,
                    collection: &routeOverlays,
                    to: mapView
                )
            }
        }

        private func routeColorHex(for segment: RouteSegment) -> String {
            switch segment.type {
            case .walking:
                return "#8E8E93"
            case .subway, .transit:
                return segment.lineColorHex ?? "#007AFF"
            case .transfer:
                return "#FF9500"
            }
        }

        private func addPolyline(
            _ coordinates: [CLLocationCoordinate2D],
            colorHex: String,
            lineWidth: CGFloat,
            level: MKOverlayLevel,
            simplify: Bool,
            collection: inout [MKOverlay],
            to mapView: MKMapView
        ) {
            guard coordinates.count >= 2 else { return }
            let displayCoordinates = simplify ? simplifiedCoordinates(coordinates) : coordinates
            let polyline = MKPolyline(coordinates: displayCoordinates, count: displayCoordinates.count)
            overlayColors[ObjectIdentifier(polyline)] = UIColor(Color(hex: colorHex))
            overlayWidths[ObjectIdentifier(polyline)] = lineWidth
            collection.append(polyline)
            mapView.addOverlay(polyline, level: level)
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
                parent.onStationSelected(station)
            }
            mapView.deselectAnnotation(annotation, animated: false)
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            let region = mapView.region
            let visibleRegion = MapVisibleRegion(
                center: region.center,
                latitudeDelta: region.span.latitudeDelta,
                longitudeDelta: region.span.longitudeDelta
            )
            regionSignature = visibleRegion.signature
            refreshMarkerVisibility(on: mapView)
            parent.onRegionChanged?(visibleRegion)
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
            let maxDelta = max(region.span.latitudeDelta, region.span.longitudeDelta)
            let visibilityLimit = station.isTransferStation ? 0.8 : 0.1
            guard maxDelta <= visibilityLimit else {
                view.isHidden = true
                return
            }

            let baseSize: CGFloat = maxDelta <= 0.055 ? 18 : (maxDelta <= 0.18 ? 9 : 6)
            let pointSize = baseSize + (station.isTransferStation ? 3 : 0)
            let labelSize: CGFloat = maxDelta <= 0.055 ? 12 : (maxDelta <= 0.18 ? 10 : 9)
            view.configure(
                station: station,
                symbol: stationSymbolImage(isTransfer: station.isTransferStation, pointSize: pointSize),
                symbolSize: pointSize,
                labelSize: labelSize
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
            renderer.lineCap = .round
            renderer.lineJoin = .round
            return renderer
        }
    }
}

private final class StationAnnotation: NSObject, MKAnnotation {
    let station: Station

    var coordinate: CLLocationCoordinate2D {
        station.coordinate
    }

    var title: String? {
        station.localizedName
    }

    var subtitle: String? {
        station.uniqueLogicalLines.map(\.localizedName).joined(separator: " / ")
    }

    init(station: Station) {
        self.station = station
    }
}

private final class StationAnnotationView: MKAnnotationView {
    private let symbolView = UIImageView()
    private let tagView = UIView()
    private let chineseLabel = UILabel()
    private let englishLabel = UILabel()

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

    func configure(station: Station, symbol: UIImage, symbolSize: CGFloat, labelSize: CGFloat) {
        symbolView.image = symbol
        symbolView.frame = CGRect(x: 0, y: 0, width: symbolSize, height: symbolSize)

        chineseLabel.text = AppLocalization.chinese(station.name)
        chineseLabel.font = .systemFont(ofSize: labelSize, weight: .semibold)
        chineseLabel.textColor = .label
        chineseLabel.sizeToFit()

        englishLabel.text = station.nameEn ?? station.namePinyin
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
