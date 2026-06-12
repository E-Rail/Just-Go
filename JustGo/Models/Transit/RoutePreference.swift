import Foundation

enum RoutePreference: String, Codable, CaseIterable, Identifiable {
    case metroFirst
    case fastest
    case leastWalking
    case fewestTransfers
    case leastConfusing
    case luggageFriendly
    case elderlyFriendly
    case officialDataOnly
    case stepFreeSupport

    var id: Self { self }

    var title: String {
        switch self {
        case .metroFirst:
            return "Transit First"
        case .fastest:
            return "Fastest"
        case .leastWalking:
            return "Least Walking"
        case .fewestTransfers: return "Fewest Transfers"
        case .leastConfusing: return "Least Confusing"
        case .luggageFriendly: return "Luggage Friendly"
        case .elderlyFriendly: return "Elderly Friendly"
        case .officialDataOnly: return "Official Data Only"
        case .stepFreeSupport: return "Step-Free Support"
        }
    }

    var icon: String {
        switch self {
        case .metroFirst:
            return "bus.fill"
        case .fastest:
            return "clock"
        case .leastWalking:
            return "figure.walk"
        case .fewestTransfers: return "arrow.triangle.branch"
        case .leastConfusing: return "signpost.right.fill"
        case .luggageFriendly: return "suitcase.fill"
        case .elderlyFriendly: return "figure.walk.motion"
        case .officialDataOnly: return "checkmark.seal.fill"
        case .stepFreeSupport: return "accessibility"
        }
    }

    init(routeStrategy: RouteStrategy) {
        switch routeStrategy {
        case .metroFirst:
            self = .metroFirst
        case .fastest:
            self = .fastest
        case .leastWalking:
            self = .leastWalking
        }
    }

    static let primary: [RoutePreference] = [.fastest, .leastWalking, .fewestTransfers, .leastConfusing]

    var isPrimary: Bool {
        Self.primary.contains(self)
    }
}
