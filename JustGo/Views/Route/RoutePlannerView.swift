import SwiftUI

struct RoutePlannerView: View {
    @Environment(DIContainer.self) private var container
    @Environment(AppState.self) var appState
    @Environment(TripMemoryService.self) var tripMemoryService
    @State var viewModel: RoutePlannerViewModel?
    @State private var showResults = false
    @FocusState var focusedField: RouteInputField?
    @State private var showCityPicker = false
    @State var showSaveCurrentTrip = false
    @State var savedTripName = ""

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                ScrollView {
                    VStack(spacing: 20) {
                        citySelector
                        routeInputSection
                        quickTagsSection
                        if !tripMemoryService.savedTrips.isEmpty {
                            savedTripsSection
                        }
                        accessibilityFiltersSection
                        saveCurrentTripButton
                        searchButton
                        if viewModel?.recentRoutes.isEmpty == false {
                            recentRoutesSection
                        }
                    }
                    .padding()
                }

                activeSuggestionDropdown
                    .padding(.horizontal)
                    .padding(.top, 132)
                    .zIndex(50)
            }
            .navigationTitle(AppLocalization.localized("Route Planner"))
            .navigationBarTitleDisplayMode(.large)
            .background(Color(.systemGroupedBackground))
            .sheet(isPresented: $showCityPicker) {
                CityPickerView(selectedCity: Binding(
                    get: { appState.selectedCity },
                    set: { appState.selectedCity = $0 }
                ))
            }
            .onChange(of: appState.selectedCity?.id) { _, _ in
                viewModel?.cityChanged(to: appState.selectedCity)
            }
            .navigationDestination(isPresented: $showResults) {
                if let viewModel = viewModel {
                    RouteResultsView(viewModel: viewModel)
                }
            }
            .sheet(isPresented: $showSaveCurrentTrip) {
                saveCurrentTripSheet
            }
        }
        .task {
            if viewModel == nil {
                viewModel = container.makeRoutePlannerViewModel()
            }
            viewModel?.cityChanged(to: appState.selectedCity)
        }
    }

    private var citySelector: some View {
        Button(action: { showCityPicker = true }) {
            HStack {
                Image(systemName: "building.2.fill")
                    .foregroundStyle(.blue)
                Text(AppLocalization.localized("City"))
                Spacer()
                Text(appState.selectedCity?.localizedName ?? AppLocalization.localized("Select City"))
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }

    private var errorAlertIsPresented: Binding<Bool> {
        Binding(
            get: { viewModel?.errorMessage != nil && viewModel?.routes.isEmpty == true },
            set: { if !$0 { viewModel?.errorMessage = nil } }
        )
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
                        stationField(
                            placeholder: "From",
                            field: .origin
                        )

                        stationField(
                            placeholder: "To",
                            field: .destination
                        )
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
                    .accessibilityLabel(AppLocalization.localized("Swap origin and destination"))
                }
            }
        }
        .zIndex(30)
    }

    @ViewBuilder
    private var activeSuggestionDropdown: some View {
        if let activeSuggestions {
            suggestionDropdown(
                suggestions: activeSuggestions.suggestions,
                select: { viewModel?.selectPlace($0, for: activeSuggestions.field) }
            )
            .padding(.top, activeSuggestions.field == .destination ? 56 : 0)
        }
    }

    private var activeSuggestions: (field: RouteInputField, suggestions: [TransitPlace])? {
        let suggestions = viewModel?.suggestions(for: focusedField) ?? []
        guard let focusedField, !suggestions.isEmpty else { return nil }
        return (focusedField, suggestions)
    }

    private func stationField(
        placeholder: LocalizedStringKey,
        field: RouteInputField
    ) -> some View {
        TextField(placeholder, text: Binding(
            get: { viewModel?.name(for: field) ?? "" },
            set: { viewModel?.updateName($0, for: field) }
        ))
            .focused($focusedField, equals: field)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .textFieldStyle(.plain)
            .padding(12)
            .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 10))
    }

    private func suggestionDropdown(
        suggestions: [TransitPlace],
        select: @escaping (TransitPlace) -> Void
    ) -> some View {
        VStack(spacing: 0) {
            ForEach(suggestions) { place in
                Button {
                    select(place)
                    focusedField = nil
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(place.name)
                                .font(.subheadline)
                            if let detailText = place.detailText {
                                Text(detailText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                }
                .buttonStyle(.plain)

                if place.id != suggestions.last?.id {
                    Divider()
                        .padding(.leading, 12)
                }
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.16), radius: 12, y: 6)
    }

    private var searchButton: some View {
        Button(action: {
            Task {
                await viewModel?.searchRoutes()
                showResults = viewModel?.routes.isEmpty == false
            }
        }) {
            HStack {
                if viewModel?.isLoading == true {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: "magnifyingglass")
                }
                Text(AppLocalization.localized("Find Routes"))
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(viewModel?.canSearch == true ? Color.blue : Color.gray)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .disabled(viewModel?.canSearch != true || viewModel?.isLoading == true)
        .alert(AppLocalization.localized("No Routes Found"), isPresented: errorAlertIsPresented) {
            Button(AppLocalization.localized("OK"), role: .cancel) {}
        } message: {
            Text(viewModel?.errorMessage ?? "")
        }
    }
}
