import SwiftUI

struct RouteDetailView: View {
    private let initialRoute: Route
    let preference: RoutePreference
    let alternatives: [Route]
    @State var selectedRouteID: UUID
    @State var showRouteReport = false
    @State var showTripNote = false
    @State var showExpandedRouteMap = false
    @State var tripNote = ""
    @State var routeReportNote = ""
    @State var routeReportSeverity: AccessibilityReportSeverity = .medium
    @State var metroNetworks: [MetroNetwork] = []
    @Environment(DIContainer.self) private var container
    @Environment(AppState.self) var appState
    @Environment(TripMemoryService.self) var tripMemoryService
    @Environment(AccessibilityReportService.self) var accessibilityReportService

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if alternatives.count > 1 {
                    RouteTabs(routes: alternatives, selection: $selectedRouteID)
                }
                routeSummaryCard
                tripConfidenceCard
                routeMapPreview
                accessGuidanceCard
                routeFeasibilityCard
                segmentsTimeline
                riderTrustActions
            }
            .padding()
        }
        .navigationTitle(AppLocalization.localized("Route Details"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showRouteReport) {
            routeReportSheet
        }
        .sheet(isPresented: $showTripNote) {
            tripNoteSheet
        }
        .fullScreenCover(isPresented: $showExpandedRouteMap) {
            FullScreenRouteMapView(route: route, metroNetworks: metroNetworks)
        }
        .task(id: route.networkCityID ?? appState.selectedCity?.id) {
            guard let cityID = route.networkCityID ?? appState.selectedCity?.id,
                  cityID != "automatic",
                  let network = await container.metroNetworkProvider.network(for: cityID) else {
                metroNetworks = []
                return
            }
            metroNetworks = [network]
        }
    }

    init(
        route: Route,
        preference: RoutePreference = .fastest,
        alternatives: [Route] = []
    ) {
        initialRoute = route
        self.preference = preference
        self.alternatives = alternatives.contains(where: { $0.id == route.id })
            ? alternatives
            : [route] + alternatives
        _selectedRouteID = State(initialValue: route.id)
    }

    var route: Route {
        alternatives.first { $0.id == selectedRouteID } ?? initialRoute
    }

    private var routeMapPreview: some View {
        TransitMapView(
            visibleRegion: .constant(route.previewRegion),
            stations: [],
            metroNetworks: metroNetworks,
            route: route,
            showsUserLocation: false,
            onRegionChanged: nil,
            onStationSelected: { _ in }
        )
        .frame(height: 220)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(alignment: .topTrailing) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.white)
                .padding(8)
                .background(.black.opacity(0.55), in: Circle())
                .padding(10)
        }
        .overlay(alignment: .bottomTrailing) {
            if !metroNetworks.isEmpty {
                MetroGeometryAttributionView()
                    .padding(8)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture {
            showExpandedRouteMap = true
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(AppLocalization.localized("Open route map full screen"))
    }

    private var routeSummaryCard: some View {
        GlassCard {
            VStack(spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(route.origin)
                            .font(.headline)
                        Text(AppLocalization.localized("Origin"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)

                    Spacer()

                    VStack(alignment: .trailing, spacing: 4) {
                        Text(route.destination)
                            .font(.headline)
                        Text(AppLocalization.localized("Destination"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                HStack(spacing: 20) {
                    StatItem(title: AppLocalization.localized("Duration"), value: route.formattedDuration, icon: "clock")
                    StatItem(title: AppLocalization.localized("Stops"), value: "\(route.totalStops)", icon: "tram")
                    StatItem(title: AppLocalization.localized("Transfers"), value: "\(route.transferCount)", icon: "arrow.triangle.2.circlepath")
                }

                if route.isFullyAccessible {
                    HStack {
                        Image(systemName: "figure.roll")
                            .foregroundStyle(.green)
                        Text(AppLocalization.localized("Fully Accessible Route"))
                            .font(.subheadline)
                            .foregroundStyle(.green)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.green.opacity(0.1), in: Capsule())
                }
            }
        }
    }

    private var tripConfidenceCard: some View {
        TripConfidenceCard(confidence: currentConfidence)
    }

    private var riderTrustActions: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(AppLocalization.localized("Rider Notes"))
                    .font(.headline)

                Button {
                    tripNote = ""
                    showTripNote = true
                } label: {
                    Label(AppLocalization.localized("Mark complete or add trip note"), systemImage: "checkmark.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button {
                    routeReportNote = ""
                    routeReportSeverity = .medium
                    showRouteReport = true
                } label: {
                    Label(AppLocalization.localized("Report route issue"), systemImage: "exclamationmark.bubble")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    var currentFeasibility: RouteFeasibility {
        container.routeFeasibilityService.feasibility(
            for: route,
            personalReports: accessibilityReportService.reports(affecting: route)
        )
    }

    private var currentConfidence: RouteConfidence {
        container.routeConfidenceService.confidence(
            for: route,
            feasibility: currentFeasibility,
            preference: preference,
            alternatives: alternatives
        )
    }
}
