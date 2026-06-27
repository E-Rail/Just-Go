import SwiftUI
import MapKit

/// Wraps Apple's native place card (`MKMapItemDetailViewController`) so it can be
/// presented from SwiftUI when the user taps a non-station point of interest.
/// `displaysMap` is false because the app's map is already on screen behind the sheet.
struct MapItemDetailSheet: UIViewControllerRepresentable {
    let mapItem: MKMapItem
    let onDismiss: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onDismiss: onDismiss)
    }

    func makeUIViewController(context: Context) -> MKMapItemDetailViewController {
        let controller = MKMapItemDetailViewController(mapItem: mapItem, displaysMap: false)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: MKMapItemDetailViewController, context: Context) {
        controller.mapItem = mapItem
    }

    final class Coordinator: NSObject, MKMapItemDetailViewControllerDelegate {
        private let onDismiss: () -> Void

        init(onDismiss: @escaping () -> Void) {
            self.onDismiss = onDismiss
        }

        func mapItemDetailViewControllerDidFinish(_ detailViewController: MKMapItemDetailViewController) {
            onDismiss()
        }
    }
}
