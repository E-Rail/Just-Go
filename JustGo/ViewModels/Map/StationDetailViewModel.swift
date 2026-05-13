import Foundation

@Observable
final class StationDetailViewModel {
    var station: Station?
    var arrivals: [RealTimeArrival] = []
    var isLoading = false
    var errorMessage: String?

    private let aMapService: AMapService

    init(aMapService: AMapService) {
        self.aMapService = aMapService
    }

    func loadStation(_ station: Station) {
        self.station = station
    }

    func loadRealTimeArrivals() async {
        guard let station = station else { return }

        isLoading = true
        arrivals = []
        defer { isLoading = false }

        do {
            for line in station.lines {
                let lineArrivals = try await aMapService.getRealTimeArrivals(
                    lineID: line.lineID,
                    stationID: station.stationID
                )
                arrivals.append(contentsOf: lineArrivals)
            }
            arrivals.sort {
                ($0.minutesRemaining ?? Int.max) < ($1.minutesRemaining ?? Int.max)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    var accessibilityInfo: StationAccessibility? {
        station?.accessibility
    }

    var isAccessible: Bool {
        accessibilityInfo?.isFullyAccessible ?? false
    }

    var hasElevator: Bool {
        accessibilityInfo?.hasElevator ?? false
    }

    var hasEscalator: Bool {
        accessibilityInfo?.hasEscalator ?? false
    }

    var elevatorStatus: ElevatorStatus {
        accessibilityInfo?.elevatorStatusEnum ?? .unknown
    }

    var accessibilityBadges: [AccessibilityBadge] {
        guard let info = accessibilityInfo else { return [] }

        var badges: [AccessibilityBadge] = []

        if info.hasElevator {
            badges.append(AccessibilityBadge(
                icon: "arrow.up.arrow.down.circle.fill",
                label: "Elevator",
                status: info.elevatorStatusEnum == .operational ? .available : .unavailable
            ))
        }

        if info.hasWheelchairRamp {
            badges.append(AccessibilityBadge(
                icon: "figure.roll",
                label: "Wheelchair Access",
                status: .available
            ))
        }

        if info.hasTactilePath {
            badges.append(AccessibilityBadge(
                icon: "hand.raised.fill",
                label: "Tactile Path",
                status: .available
            ))
        }

        if info.hasAudioAnnouncement {
            badges.append(AccessibilityBadge(
                icon: "speaker.wave.2.fill",
                label: "Audio",
                status: .available
            ))
        }

        if info.hasVisualAnnouncement {
            badges.append(AccessibilityBadge(
                icon: "eye.fill",
                label: "Visual Display",
                status: .available
            ))
        }

        return badges
    }
}

struct AccessibilityBadge: Identifiable {
    let id = UUID()
    let icon: String
    let label: String
    let status: BadgeStatus

    enum BadgeStatus {
        case available
        case unavailable
        case unknown

        var color: String {
            switch self {
            case .available: return "green"
            case .unavailable: return "red"
            case .unknown: return "gray"
            }
        }
    }
}
