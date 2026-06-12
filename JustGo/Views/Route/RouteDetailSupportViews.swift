import SwiftUI

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
                        Text("\(confidence.score) / 100")
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
    let metroNetworks: [MetroNetwork]
    @Environment(\.dismiss) private var dismiss
    @State private var visibleRegion: MapVisibleRegion?

    init(route: Route, metroNetworks: [MetroNetwork]) {
        self.route = route
        self.metroNetworks = metroNetworks
        _visibleRegion = State(initialValue: route.previewRegion)
    }

    var body: some View {
        NavigationStack {
            TransitMapView(
                visibleRegion: $visibleRegion,
                stations: [],
                metroNetworks: metroNetworks,
                route: route,
                showsUserLocation: false,
                onRegionChanged: nil,
                onStationSelected: { _ in }
            )
            .ignoresSafeArea(edges: .bottom)
            .overlay(alignment: .bottomTrailing) {
                if !metroNetworks.isEmpty {
                    MetroGeometryAttributionView()
                        .padding(8)
                }
            }
            .navigationTitle(AppLocalization.localized("Route Map"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                    }
                    .accessibilityLabel(AppLocalization.localized("Close route map"))
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
            Text(AppLocalization.localized(title))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
