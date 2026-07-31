import SwiftUI

extension RouteDetailView {
    /// Maps an access-point source to a confidence label for the access guidance card.
    /// Returns nil for the generic placeholder so the chip is hidden when no specific exit exists.
    func accessConfidence(for guide: RouteAccessGuide) -> DataConfidence? {
        guard let source = guide.accessPoint?.source else { return nil }
        switch source {
        case .specificEntrance, .localStationData: return .official
        case .inferred, .mapKit: return .estimated
        case .stationPOI, .routeBoundary: return nil
        }
    }

}

extension RouteFeasibilityLevel {
    var color: Color {
        switch self {
        case .good:
            return .green
        case .caution:
            return .orange
        case .risky:
            return .red
        case .unknown:
            return .gray
        }
    }

    var iconName: String {
        switch self {
        case .good:
            return "checkmark.circle.fill"
        case .caution:
            return "exclamationmark.triangle.fill"
        case .risky:
            return "xmark.octagon.fill"
        case .unknown:
            return "questionmark.circle.fill"
        }
    }
}
