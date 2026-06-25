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
        ZStack {
            TransitMapView(
                visibleRegion: $visibleRegion,
                stations: [],
                metroNetworks: metroNetworks,
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
                if !metroNetworks.isEmpty {
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
