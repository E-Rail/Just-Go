import SwiftUI

extension RouteConfidenceLevel {
    var color: Color {
        switch self {
        case .high: return .green
        case .medium: return .orange
        case .low: return .red
        }
    }
}

struct TripConfidenceCard: View {
    let confidence: RouteConfidence

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(AppLocalization.localized("Trip Confidence"))
                            .font(.headline)
                        Text(confidence.level.summary)
                            .font(.subheadline)
                            .foregroundStyle(confidence.level.color)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(AppLocalization.text(
                            english: "\(confidence.score) / 100",
                            simplified: "\(confidence.score)分",
                            traditional: "\(confidence.score)分"
                        ))
                            .font(.title3)
                            .fontWeight(.bold)
                        Text(confidence.level.title)
                            .font(.caption)
                            .foregroundStyle(confidence.level.color)
                    }
                    .accessibilityLabel("\(confidence.level.title), \(confidence.score) \(AppLocalization.localized("out of 100"))")
                }

                Text(confidence.explanation)
                    .font(.subheadline)

                ForEach(confidence.positiveReasons.prefix(3), id: \.self) { reason in
                    Label(reason, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }

                ForEach(confidence.warnings.prefix(3), id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(AppLocalization.localized("Based on available data, not a safety guarantee."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct FullScreenRouteMapView: View {
    let route: Route
    @Environment(\.dismiss) private var dismiss
    @State private var visibleRegion: MapVisibleRegion?

    init(route: Route) {
        self.route = route
        _visibleRegion = State(initialValue: route.previewRegion)
    }

    /// Markers for every stop the route passes through, built from the route's own stop data
    /// rather than a city-pack lookup — this is a map trace, not an interactive station picker.
    private var routeStations: [Station] {
        route.stationTimelineStops.map { $0.asStation(cityID: route.networkCityID ?? "") }
    }

    var body: some View {
        ZStack {
            TransitMapView(
                visibleRegion: $visibleRegion,
                stations: routeStations,
                // Only the traveled geometry: the route's own per-segment polylines.
                // Tracing the involved lines end to end made a short hop on a loop line
                // read as riding the whole loop.
                metroNetworks: [],
                route: route,
                showsUserLocation: false,
                onRegionChanged: { visibleRegion = $0 },
                onStationSelected: { _ in }
            )
            .ignoresSafeArea()

            VStack {
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.4), radius: 3)
                    }
                    .accessibilityLabel(AppLocalization.localized("Close route map"))
                    .padding(16)
                }
                Spacer()
                // Bundled-network routes draw OSM-derived segment geometry, which requires
                // attribution; Apple-transit routes carry Apple polylines and don't.
                if route.networkCityID != nil {
                    HStack {
                        Spacer()
                        MetroGeometryAttributionView()
                            .padding(8)
                    }
                }
            }
        }
    }
}

struct StatItem: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Single source of truth for how a `DataConfidence` reads visually — fixed semantic
/// indicators (official/verified = green, anything estimated/pending/personal = orange,
/// unavailable = red, unknown = gray), intentionally not theme-tinted. Shared by
/// `DataConfidenceChip` below and `StationDetailView`'s confidence rows.
extension DataConfidence {
    var color: Color {
        switch self {
        case .official, .communityVerified: return .green
        case .estimated, .mapKit, .sourcePending, .personal: return .orange
        case .unavailable: return .red
        case .unknown: return .gray
        }
    }
}

/// Compact capsule labeling the data source behind a piece of guidance:
/// official (green) / estimated (orange) / not available (red) / no data (gray).
struct DataConfidenceChip: View {
    let confidence: DataConfidence
    var compact = false

    private var icon: String {
        switch confidence {
        case .official, .communityVerified: return "checkmark.seal.fill"
        case .estimated, .mapKit, .sourcePending, .personal: return "exclamationmark.circle.fill"
        case .unavailable: return "xmark.circle.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
            Text(confidence.label)
                .font(.caption2)
                .fontWeight(.medium)
        }
        .padding(.horizontal, compact ? 6 : 8)
        .padding(.vertical, compact ? 2 : 4)
        .background(confidence.color, in: Capsule())
        .foregroundStyle(.white)
    }
}
