import SwiftUI

struct RoutePlannerView: View {
    @Environment(DIContainer.self) private var container
    @Environment(AppState.self) private var appState
    @Environment(TripMemoryService.self) private var tripMemoryService
    @State private var viewModel: RoutePlannerViewModel?
    @State private var showResults = false
    @FocusState private var focusedField: RouteInputField?
    @State private var showCityPicker = false
    @State private var showSaveCurrentTrip = false
    @State private var savedTripName = ""

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
                viewModel = RoutePlannerViewModel(
                    routePlanningService: container.routePlanningService,
                    placeSearchProvider: container.placeSearchProvider,
                    locationService: container.locationService
                )
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
                        if let type = place.typeCode {
                            Text(type)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
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

    private var quickTagsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    quickTagButton(
                        title: AppLocalization.localized("Current Location"),
                        icon: "location.fill",
                        isSaved: true
                    ) {
                        let field = quickTagTargetField
                        Task {
                            await viewModel?.useCurrentLocation(for: field)
                        }
                    }

                    ForEach(QuickPlaceKind.allCases) { kind in
                        let quickPlace = viewModel?.quickPlace(for: kind)
                        quickTagButton(
                            title: quickPlace?.name ?? kind.title,
                            icon: kind.icon,
                            isSaved: quickPlace != nil
                        ) {
                            let field = quickTagTargetField
                            if let quickPlace {
                                viewModel?.useQuickPlace(quickPlace, for: field)
                            } else {
                                viewModel?.beginSavingQuickPlace(kind)
                                focusedField = field
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }

            if let pendingKind = viewModel?.pendingQuickPlaceKind {
                Text(String(format: AppLocalization.localized("Search a place to save %@"), pendingKind.title))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var quickTagTargetField: RouteInputField {
        switch focusedField {
        case .origin:
            return .origin
        case .destination:
            return .destination
        case nil:
            return (viewModel?.originName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) ? .origin : .destination
        }
    }

    private func quickTagButton(title: String, icon: String, isSaved: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            quickTagLabel(title: title, icon: icon, isSaved: isSaved)
        }
        .buttonStyle(.plain)
    }

    private func quickTagLabel(title: String, icon: String, isSaved: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
            Text(title)
                .font(.caption)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isSaved ? Color.blue.opacity(0.12) : Color(.systemGray5), in: Capsule())
        .foregroundStyle(isSaved ? .blue : .primary)
    }

    private var accessibilityFiltersSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
            Text(AppLocalization.localized("Travel Support"))
                .font(.headline)

                Toggle(isOn: Binding(
                    get: { viewModel?.requiresWheelchairAccess ?? false },
                    set: { viewModel?.requiresWheelchairAccess = $0 }
                )) {
                    Label(AppLocalization.localized("Wheelchair Access"), systemImage: "figure.roll")
                }

                Toggle(isOn: Binding(
                    get: { viewModel?.requiresElevator ?? false },
                    set: { viewModel?.requiresElevator = $0 }
                )) {
                    Label(AppLocalization.localized("Elevator Required"), systemImage: "arrow.up.arrow.down.circle")
                }

                Toggle(isOn: Binding(
                    get: { viewModel?.avoidStairs ?? false },
                    set: { viewModel?.avoidStairs = $0 }
                )) {
                    Label(AppLocalization.localized("Avoid Stairs"), systemImage: "stairs")
                }
            }
        }
    }

    private var savedTripsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AppLocalization.localized("Saved Trips"))
                .font(.headline)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(tripMemoryService.savedTrips.prefix(6)) { trip in
                        Button {
                            _ = tripMemoryService.markSavedTripUsed(id: trip.id)
                            viewModel?.useSavedTrip(trip)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(trip.name)
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                    .lineLimit(1)
                                Text(trip.routeTitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                if trip.hasAccessibilityOverrides {
                                    Label(AppLocalization.localized("Accessibility overrides"), systemImage: "accessibility")
                                        .font(.caption2)
                                        .foregroundStyle(.blue)
                                }
                            }
                            .frame(width: 180, alignment: .leading)
                            .padding()
                            .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var saveCurrentTripButton: some View {
        Button {
            savedTripName = defaultSavedTripName
            showSaveCurrentTrip = true
        } label: {
            Label(AppLocalization.localized("Save this trip"), systemImage: "bookmark")
                .font(.subheadline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color(.systemGray5), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(viewModel?.canSearch != true)
        .opacity(viewModel?.canSearch == true ? 1 : 0.55)
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

    private var recentRoutesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AppLocalization.localized("Recent Routes"))
                .font(.headline)

            List {
                ForEach(viewModel?.recentRoutes ?? []) { route in
                    Button {
                        viewModel?.useRecentRoute(route)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(route.originStationName) → \(route.destinationStationName)")
                                    .font(.body)
                                Text([route.lineName, route.duration].compactMap { $0 }.joined(separator: " • "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { offsets in
                    viewModel?.deleteRecentRoutes(at: offsets)
                }
            }
            .listStyle(.plain)
            .frame(minHeight: 80, maxHeight: 220)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private var saveCurrentTripSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(AppLocalization.localized("Trip name"), text: $savedTripName)
                    Text(defaultSavedTripName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text(AppLocalization.localized("Saved Trip"))
                }

                Section {
                    Label(AppLocalization.localized("Accessibility filters will be saved with this trip."), systemImage: "accessibility")
                }
            }
            .navigationTitle(AppLocalization.localized("Save Trip"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLocalization.localized("Cancel")) {
                        showSaveCurrentTrip = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppLocalization.localized("Save")) {
                        saveCurrentTrip()
                    }
                    .disabled(viewModel?.canSearch != true)
                }
            }
        }
    }

    private var defaultSavedTripName: String {
        let origin = viewModel?.originSnapshot()?.name ?? AppLocalization.localized("Origin")
        let destination = viewModel?.destinationSnapshot()?.name ?? AppLocalization.localized("Destination")
        return "\(origin) -> \(destination)"
    }

    private func saveCurrentTrip() {
        guard let city = appState.selectedCity,
              let origin = viewModel?.originSnapshot(),
              let destination = viewModel?.destinationSnapshot(),
              let filter = viewModel?.accessibilityFilter else { return }

        tripMemoryService.createSavedTrip(
            name: savedTripName,
            origin: origin,
            destination: destination,
            city: city,
            preferredStrategy: nil,
            preferredRoutePreference: viewModel?.sortStrategy,
            accessibilityFilter: filter
        )
        showSaveCurrentTrip = false
    }
}
