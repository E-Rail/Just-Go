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

/// The single universal way a route's confidence reads: a dial filled clockwise from twelve
/// o'clock to `score`/100 of the way round — tinted green/orange/red by the level — with the
/// score at its center. Shared by the route-selection rows and the route-detail card so the same
/// number and geometry appear everywhere confidence is shown.
///
/// The arc used to sweep forever instead of stopping at the score. That is a spinner's motion,
/// and a spinner means "still working" — so a settled 42 read as a value still loading, and the
/// full circle read as 100 regardless of the number inside it. The fill is now the score.
struct ConfidenceScoreRing: View {
    let score: Int
    let color: Color
    var size: CGFloat = 48
    var lineWidth: CGFloat = 4

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The score is already clamped to 0-100 by `RouteConfidenceService`, but the ring must not
    /// depend on that: an over-full trim silently wraps past twelve and understates the score.
    private var fraction: Double { min(1, max(0, Double(score) / 100)) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.15), lineWidth: lineWidth)
            Circle()
                // Derived from `score` rather than grown in from `@State` on appear: `onAppear`
                // does not fire under `ImageRenderer` or in previews, and a fill that depends on
                // it renders as an empty ring there — the one failure that looks like real data.
                .trim(from: 0, to: fraction)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                // `trim` starts at three o'clock; a dial has to start at twelve.
                .rotationEffect(.degrees(-90))
                .animation(reduceMotion ? nil : .easeOut(duration: 0.35), value: fraction)
            Text("\(score)")
                .font(.system(size: size * 0.34, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AppLocalization.text(
            english: "Confidence \(score) out of 100",
            simplified: "置信度 \(score) 分（满分 100）",
            traditional: "信心度 \(score) 分（滿分 100）"
        ))
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
                    VStack(spacing: 4) {
                        ConfidenceScoreRing(
                            score: confidence.score,
                            color: confidence.level.color,
                            size: 56
                        )
                        Text(confidence.level.title)
                            .font(.caption)
                            .foregroundStyle(confidence.level.color)
                    }
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
        // Black, not white: these are iOS system green/orange/red/gray, all mid-luminance
        // colors that fail WCAG AA contrast against white text (verified ~2.2-3.6:1) but
        // pass comfortably against black (~5.9-9.6:1), in both light and dark appearance.
        .foregroundStyle(.black)
        .accessibilityElement(children: .combine)
    }
}
