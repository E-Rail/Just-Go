import MapKit
import UIKit

/// The very first `MKMapView` created in a process pays a one-time engine/tile-pipeline
/// warm-up cost, independent of network speed — confirmed on a real device as the cause of a
/// slow first visit to the Map tab (subsequent visits are fast). The app opens on the Route tab
/// by default, so there's headroom to pay this cost during launch instead of on first tap.
@MainActor
enum MapKitPrewarmer {
    private static var warmupMapView: MKMapView?

    static func prewarm() {
        guard warmupMapView == nil,
              let window = UIApplication.shared.connectedScenes
                .compactMap({ ($0 as? UIWindowScene)?.windows.first })
                .first else { return }
        // A parentless view never gets a real layout/render pass, so it must actually be
        // attached (hidden) to trigger MapKit's one-time setup rather than just allocate one.
        let mapView = MKMapView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        mapView.isHidden = true
        window.addSubview(mapView)
        warmupMapView = mapView
    }
}
