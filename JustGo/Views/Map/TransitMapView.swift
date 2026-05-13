import MapKit
import SwiftUI

struct TransitMapView: UIViewRepresentable {
    @Binding var visibleRegion: MapVisibleRegion?
    let stations: [Station]
    let subwayLines: [SubwayLineMapOverlay]
    let route: Route?
    let showsUserLocation: Bool
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
        private var contentSignature = ""
        private var annotationStations: [ObjectIdentifier: Station] = [:]
        private var overlayColors: [ObjectIdentifier: UIColor] = [:]

        init(parent: TransitMapView) {
            self.parent = parent
        }

        func sync(parent: TransitMapView, on mapView: MKMapView) {
            self.parent = parent
            mapView.showsUserLocation = parent.showsUserLocation
            syncRegion(on: mapView)
            syncContent(on: mapView)
        }

        private func syncRegion(on mapView: MKMapView) {
            guard let visibleRegion = parent.visibleRegion else { return }
            let nextSignature = visibleRegion.signature
            guard nextSignature != regionSignature else { return }
            mapView.setRegion(visibleRegion.mkCoordinateRegion, animated: true)
            regionSignature = nextSignature
        }

        private func syncContent(on mapView: MKMapView) {
            let nextSignature = [
                parent.stations.map(\.stationID).joined(separator: ","),
                parent.subwayLines.map(\.id).joined(separator: ","),
                parent.route?.id.uuidString ?? "no-route"
            ].joined(separator: "|")

            guard nextSignature != contentSignature else { return }
            contentSignature = nextSignature
            annotationStations.removeAll()
            overlayColors.removeAll()

            mapView.removeAnnotations(mapView.annotations.filter { !($0 is MKUserLocation) })
            mapView.removeOverlays(mapView.overlays)

            for overlay in parent.subwayLines {
                addPolyline(overlay.polylineCoordinates, colorHex: overlay.colorHex, to: mapView)
            }

            if let route = parent.route {
                addRoute(route, to: mapView)
            }

            let annotations = parent.stations.map { station in
                let annotation = StationAnnotation(station: station)
                annotationStations[ObjectIdentifier(annotation)] = station
                return annotation
            }
            mapView.addAnnotations(annotations)
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
                    colorHex: segment.type == .walking ? "#8E8E93" : (segment.lineColorHex ?? "#007AFF"),
                    to: mapView
                )
            }
        }

        private func addPolyline(_ coordinates: [CLLocationCoordinate2D], colorHex: String, to mapView: MKMapView) {
            guard coordinates.count >= 2 else { return }
            let polyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
            overlayColors[ObjectIdentifier(polyline)] = UIColor(Color(hex: colorHex))
            mapView.addOverlay(polyline, level: .aboveRoads)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let stationAnnotation = annotation as? StationAnnotation else { return nil }

            let identifier = "station"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView ??
                MKMarkerAnnotationView(annotation: stationAnnotation, reuseIdentifier: identifier)
            view.annotation = stationAnnotation
            view.markerTintColor = stationAnnotation.station.isTransferStation ? .systemOrange : .systemBlue
            view.glyphImage = UIImage(systemName: stationAnnotation.station.isTransferStation ? "arrow.triangle.branch" : "tram.fill")
            view.canShowCallout = true
            view.displayPriority = stationAnnotation.station.isTransferStation ? .required : .defaultHigh
            return view
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let annotation = view.annotation else { return }
            if let station = annotationStations[ObjectIdentifier(annotation)] {
                parent.onStationSelected(station)
            }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let polyline = overlay as? MKPolyline else {
                return MKOverlayRenderer(overlay: overlay)
            }

            let renderer = MKPolylineRenderer(polyline: polyline)
            renderer.strokeColor = overlayColors[ObjectIdentifier(polyline)] ?? .systemBlue
            renderer.lineWidth = 5
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
        station.lines.map(\.localizedName).joined(separator: " / ")
    }

    init(station: Station) {
        self.station = station
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
