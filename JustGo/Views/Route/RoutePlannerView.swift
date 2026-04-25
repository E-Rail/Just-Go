import SwiftUI

struct RoutePlannerView: View {
    @Environment(DIContainer.self) private var container
    @Environment(AppState.self) private var appState
    @State private var viewModel: RoutePlannerViewModel?
    @State private var showResults = false
    @State private var originSuggestions: [Station] = []
    @State private var destinationSuggestions: [Station] = []
    @State private var showOriginSuggestions = false
    @State private var showDestinationSuggestions = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    citySelector
                    routeInputSection
                    accessibilityFiltersSection
                    searchButton
                    recentRoutesSection
                }
                .padding()
            }
            .navigationTitle("Route Planner")
            .navigationBarTitleDisplayMode(.large)
            .background(Color(.systemGroupedBackground))
            .navigationDestination(isPresented: $showResults) {
                if let viewModel = viewModel {
                    RouteResultsView(viewModel: viewModel)
                }
            }
        }
        .task {
            if viewModel == nil {
                viewModel = RoutePlannerViewModel(
                    routePlanningService: container.routePlanningService,
                    stationSearchService: container.stationSearchService,
                    cityService: container.cityService
                )
            }
            viewModel?.selectedCity = appState.selectedCity
        }
    }

    private var citySelector: some View {
        GlassCard {
            HStack {
                Image(systemName: "building.2.fill")
                    .foregroundStyle(.blue)
                Text("City")
                Spacer()
                Text(appState.selectedCity?.nameEn ?? "Select City")
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var routeInputSection: some View {
        GlassCard {
            VStack(spacing: 16) {
                HStack(spacing: 12) {
                    VStack(spacing: 12) {
                        Circle()
                            .fill(.green)
                            .frame(width: 12, height: 12)
                        Rectangle()
                            .fill(.secondary)
                            .frame(width: 2, height: 24)
                        Circle()
                            .fill(.red)
                            .frame(width: 12, height: 12)
                    }

                    VStack(spacing: 12) {
                        TextField("From", text: Binding(
                            get: { viewModel?.originName ?? "" },
                            set: { viewModel?.originName = $0 }
                        ))
                        .textFieldStyle(.plain)
                        .padding(12)
                        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 10))

                        TextField("To", text: Binding(
                            get: { viewModel?.destinationName ?? "" },
                            set: { viewModel?.destinationName = $0 }
                        ))
                        .textFieldStyle(.plain)
                        .padding(12)
                        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 10))
                    }
                }

                HStack {
                    Spacer()
                    Button(action: { viewModel?.swapOriginDestination() }) {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.title3)
                            .foregroundStyle(.blue)
                            .padding(8)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .accessibilityLabel("Swap origin and destination")
                }
            }
        }
    }

    private var accessibilityFiltersSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Accessibility")
                    .font(.headline)

                Toggle(isOn: Binding(
                    get: { viewModel?.requiresWheelchairAccess ?? false },
                    set: { viewModel?.requiresWheelchairAccess = $0 }
                )) {
                    Label("Wheelchair Access", systemImage: "figure.roll")
                }

                Toggle(isOn: Binding(
                    get: { viewModel?.requiresElevator ?? false },
                    set: { viewModel?.requiresElevator = $0 }
                )) {
                    Label("Elevator Required", systemImage: "arrow.up.arrow.down.circle")
                }

                Toggle(isOn: Binding(
                    get: { viewModel?.avoidStairs ?? false },
                    set: { viewModel?.avoidStairs = $0 }
                )) {
                    Label("Avoid Stairs", systemImage: "stairs")
                }
            }
        }
    }

    private var searchButton: some View {
        Button(action: {
            Task {
                await viewModel?.searchRoutes()
                showResults = true
            }
        }) {
            HStack {
                if viewModel?.isLoading == true {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: "magnifyingglass")
                }
                Text("Find Routes")
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(viewModel?.canSearch == true ? Color.blue : Color.gray)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .disabled(viewModel?.canSearch != true || viewModel?.isLoading == true)
    }

    private var recentRoutesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent Routes")
                .font(.headline)

            GlassCard {
                VStack(spacing: 12) {
                    ForEach(0..<3) { _ in
                        HStack {
                            VStack(alignment: .leading) {
                                Text("Xidan → Wangfujing")
                                    .font(.body)
                                Text("Line 1 • 15 min")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}
