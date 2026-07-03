import SwiftUI
import MapKit

/// A small, self-contained 3D-tilted MapKit preview embedded in a Live "Go" step card.
/// `.station` shows a single point (used for `.transfer` steps); `.walkingRoute` draws
/// Apple's real, already-computed walking polyline with start/end markers (used for
/// `.walkToStation`/`.walkToDestination` steps). Distinct from `TransferStationSheet`'s
/// photorealistic Look Around preview — this is an actual tilted map camera, not a photo.
struct StepMapPreview: View {
    enum Mode {
        case station(coordinate: CLLocationCoordinate2D)
        case walkingRoute(coordinates: [CLLocationCoordinate2D])
    }

    let mode: Mode
    let tint: Color
    private let camera: MapCameraPosition

    init(mode: Mode, tint: Color) {
        self.mode = mode
        self.tint = tint
        self.camera = Self.initialCamera(for: mode)
    }

    var body: some View {
        Map(initialPosition: camera) {
            switch mode {
            case .station(let coordinate):
                Marker(AppLocalization.text(english: "Station", simplified: "车站", traditional: "車站"), coordinate: coordinate)
                    .tint(tint)
            case .walkingRoute(let coordinates):
                if let start = coordinates.first {
                    Marker(AppLocalization.text(english: "Start", simplified: "起点", traditional: "起點"), coordinate: start)
                        .tint(.gray)
                }
                if let end = coordinates.last {
                    Marker(AppLocalization.text(english: "Destination", simplified: "目的地", traditional: "目的地"), coordinate: end)
                        .tint(tint)
                }
                MapPolyline(coordinates: coordinates)
                    .stroke(tint, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            }
        }
        .mapStyle(.standard(elevation: .realistic))
        .mapControlVisibility(.hidden)
        .frame(height: 200)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private static func initialCamera(for mode: Mode) -> MapCameraPosition {
        switch mode {
        case .station(let coordinate):
            return .camera(MapCamera(centerCoordinate: coordinate, distance: 350, heading: 0, pitch: 65))
        case .walkingRoute(let coordinates):
            guard let first = coordinates.first else { return .automatic }
            guard coordinates.count > 1, let last = coordinates.last else {
                return .camera(MapCamera(centerCoordinate: first, distance: 350, heading: 0, pitch: 65))
            }
            let lats = coordinates.map(\.latitude)
            let lons = coordinates.map(\.longitude)
            let center = CLLocationCoordinate2D(
                latitude: (lats.min()! + lats.max()!) / 2,
                longitude: (lons.min()! + lons.max()!) / 2
            )
            let span = first.distance(to: last)
            let distance = min(max(span * 2.2, 350), 1400)
            return .camera(MapCamera(
                centerCoordinate: center,
                distance: distance,
                heading: bearing(from: first, to: last),
                pitch: 60
            ))
        }
    }

    private static func bearing(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> CLLocationDirection {
        let lat1 = from.latitude * .pi / 180, lat2 = to.latitude * .pi / 180
        let deltaLon = (to.longitude - from.longitude) * .pi / 180
        let y = sin(deltaLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(deltaLon)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }
}
