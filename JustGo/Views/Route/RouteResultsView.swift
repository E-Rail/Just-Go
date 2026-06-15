import SwiftUI

struct RouteResultsView: View {
    @Bindable var viewModel: RoutePlannerViewModel
    @Environment(DIContainer.self) private var container
    @Environment(AccessibilityReportService.self) private var accessibilityReportService
    @Environment(TripMemoryService.self) private var tripMemoryService
    @State private var selectedRouteID: UUID?
    @State private var showRouteDetail = false

    var body: some View {
        List {
            sortOptionsSection

            if viewModel.isLoading {
                HStack {
                    Spacer()
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(AppLocalization.localized("Finding routes..."))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    Spacer()
                }
            } else if let error = viewModel.errorMessage {
                ContentUnavailableView {
                    Label(AppLocalization.localized("No Routes Found"), systemImage: "map")
                } description: {
                    Text(error)
                }
            } else {
                routesSection
            }
        }
        .navigationTitle(AppLocalization.localized("Routes"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            ensureRouteSelection()
        }
        .onChange(of: viewModel.routes.map(\.id)) {
            ensureRouteSelection()
        }
        .navigationDestination(isPresented: $showRouteDetail) {
            if let route = selectedRoute {
                RouteDetailView(
                    route: route,
                    preference: viewModel.sortStrategy,
                    alternatives: viewModel.routes
                )
            }
        }
    }

    private var sortOptionsSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(RoutePreference.primary) { strategy in
                        SortChip(
                            title: strategy.title,
                            icon: strategy.icon,
                            isSelected: viewModel.sortStrategy == strategy
                        ) {
                            viewModel.sortStrategy = strategy
                            viewModel.sortRoutes()
                        }
                    }

                    Menu {
                        ForEach(RoutePreference.allCases.filter { !$0.isPrimary }) { strategy in
                            Button {
                                viewModel.sortStrategy = strategy
                                viewModel.sortRoutes()
                            } label: {
                                Label(strategy.title, systemImage: strategy.icon)
                            }
                        }
                    } label: {
                        Label(
                            viewModel.sortStrategy.isPrimary
                                ? AppLocalization.localized("More")
                                : viewModel.sortStrategy.title,
                            systemImage: viewModel.sortStrategy.isPrimary ? "ellipsis.circle" : viewModel.sortStrategy.icon
                        )
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(viewModel.sortStrategy.isPrimary ? Color(.systemGray5) : Color.blue)
                        .foregroundStyle(viewModel.sortStrategy.isPrimary ? Color.primary : Color.white)
                        .clipShape(Capsule())
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var routesSection: some View {
        Section {
            if !viewModel.routes.isEmpty {
                RouteTabs(
                    routes: viewModel.routes,
                    selection: Binding(
                        get: { selectedRouteID ?? viewModel.routes[0].id },
                        set: { selectedRouteID = $0 }
                    )
                )

                if let route = selectedRoute {
                    let feasibility = container.routeFeasibilityService.feasibility(
                        for: route,
                        personalReports: accessibilityReportService.reports(affecting: route)
                    )
                    RouteCard(
                        route: route,
                        confidence: container.routeConfidenceService.confidence(
                            for: route,
                            feasibility: feasibility,
                            preference: viewModel.sortStrategy,
                            alternatives: viewModel.routes
                        )
                    ) {
                        _ = tripMemoryService.recordPlannedTrip(
                            route: route,
                            cityID: route.networkCityID ?? viewModel.selectedCity?.id ?? "",
                            accessibilityFilter: viewModel.accessibilityFilter
                        )
                        showRouteDetail = true
                    }
                }
            }
        } header: {
            Text(AppLocalization.localized("Choose a route"))
        }
    }

    private var selectedRoute: Route? {
        guard let selectedRouteID else { return viewModel.routes.first }
        return viewModel.routes.first { $0.id == selectedRouteID } ?? viewModel.routes.first
    }

    private func ensureRouteSelection() {
        guard !viewModel.routes.isEmpty else {
            selectedRouteID = nil
            return
        }
        if !viewModel.routes.contains(where: { $0.id == selectedRouteID }) {
            selectedRouteID = viewModel.routes[0].id
        }
    }
}
