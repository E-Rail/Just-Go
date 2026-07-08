import SwiftUI

extension RoutePlannerView {
    var welcomeCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "tram.circle.fill")
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)
                    Text(AppLocalization.text(english: "Welcome to JustGo", simplified: "欢迎使用 JustGo", traditional: "歡迎使用 JustGo"))
                        .font(.headline)
                    Spacer()
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) { hasSeenWelcome = true }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                Text(AppLocalization.text(
                    english: "Plan metro routes across 46+ Chinese cities. Select your city above, then enter your starting station and destination.",
                    simplified: "规划中国46+城市地铁路线。选择城市，输入出发站和目的站，即可开始。",
                    traditional: "規劃中國46+城市地鐵路線。選擇城市，輸入出發站和目的站，即可開始。"
                ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { hasSeenWelcome = true }
                } label: {
                    Text(AppLocalization.text(english: "Got it", simplified: "明白了", traditional: "明白了"))
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    var smartCommuteSection: some View {
        if let (trip, isEvening) = smartCommuteTrip(for: appState.selectedCity?.id ?? "") {
            SmartCommuteCard(
                trip: trip,
                isEvening: isEvening,
                cityID: appState.selectedCity?.id ?? ""
            ) {
                viewModel?.useSavedTrip(trip)
                if isEvening {
                    viewModel?.swapOriginDestination()
                }
                Task {
                    // Credit the trip only when ITS OWN search published — inspecting the
                    // shared routes after the await would credit trip A for trip B's
                    // results when taps overlap.
                    if await viewModel?.searchRoutes() == true {
                        _ = tripMemoryService.markSavedTripUsed(id: trip.id)
                        showResults = true
                    }
                }
            }
        }
    }

    private func smartCommuteTrip(for cityID: String) -> (trip: SavedTrip, isEvening: Bool)? {
        guard !cityID.isEmpty else { return nil }
        let nowMin = ChinaClock.minutesOfDay(of: Date())
        let isMorning = nowMin >= 300 && nowMin < 660
        let isEvening = nowMin >= 960 && nowMin < 1320
        guard isMorning || isEvening else { return nil }
        let trip = tripMemoryService.savedTrips
            .filter { $0.cityID == cityID }
            .sorted {
                if $0.useCount != $1.useCount { return $0.useCount > $1.useCount }
                return ($0.lastUsedAt ?? .distantPast) > ($1.lastUsedAt ?? .distantPast)
            }
            .first
        guard let trip else { return nil }
        return (trip, isEvening)
    }

    private var anyFilterActive: Bool {
        (viewModel?.requiresWheelchairAccess ?? false)
            || (viewModel?.requiresElevator ?? false)
            || (viewModel?.avoidStairs ?? false)
    }

    private var needsFiltersExpanded: Bool {
        appState.accessibilityPreference.primaryCategory != .none || anyFilterActive
    }

    @ViewBuilder
    var accessibilityFiltersWrapper: some View {
        if needsFiltersExpanded || showAccessibilityFilters {
            accessibilityFiltersSection
        } else {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showAccessibilityFilters = true
                }
            } label: {
                Label(
                    AppLocalization.localized("Accessibility filters"),
                    systemImage: "accessibility"
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
        }
    }

    var accessibilityFiltersSection: some View {
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

    var savedTripsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AppLocalization.localized("Saved Trips"))
                .font(.headline)

            if tripMemoryService.savedTrips.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "bookmark")
                        .foregroundStyle(.secondary)
                    Text(AppLocalization.localized("Search a route, then tap 'Save this trip' to reuse it quickly"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 10))
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(tripMemoryService.savedTrips.prefix(6)) { trip in
                            Button {
                                // Saved trips keep their home city; planning a Beijing
                                // trip's coordinates against a selected Shanghai network
                                // matches nonsense nearest stations.
                                switchPlannerCity(toCityID: trip.cityID)
                                viewModel?.useSavedTrip(trip)
                                Task {
                                    // Same ownership rule as the smart-commute card above.
                                    if await viewModel?.searchRoutes() == true {
                                        _ = tripMemoryService.markSavedTripUsed(id: trip.id)
                                        showResults = true
                                    }
                                }
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
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                                .frame(width: 180, alignment: .leading)
                                .padding()
                                .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    var saveCurrentTripButton: some View {
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
        // Gated on a current successful plan, not just filled fields: an unplanned save
        // has no planned-network city and would fall back to whatever city is selected.
        .disabled(viewModel?.hasCurrentPlan != true)
        .opacity(viewModel?.hasCurrentPlan == true ? 1 : 0.55)
        .opacity(viewModel?.canSearch == true ? 1 : 0.55)
    }

    var recentRoutesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AppLocalization.localized("Recent Routes"))
                .font(.headline)

            if (viewModel?.recentRoutes ?? []).isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "clock")
                        .foregroundStyle(.secondary)
                    Text(AppLocalization.localized("Your last 10 routes will appear here for quick access"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 10))
            } else {
                VStack(spacing: 0) {
                    ForEach(viewModel?.recentRoutes ?? []) { route in
                        Button {
                            // Recents fill by NAME and resolve at search time in the
                            // current city — a Beijing name under Shanghai silently
                            // matches a same-named Shanghai station. Legacy rows recover
                            // their city from the station ID prefix.
                            if let cityID = route.resolvedCityID {
                                switchPlannerCity(toCityID: cityID)
                            }
                            viewModel?.useRecentRoute(route)
                            scrollToTopTrigger.toggle()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("\(route.originStationName) → \(route.destinationStationName)")
                                        .font(.body)
                                    Text([route.lineName, route.displayDuration].compactMap { $0 }.joined(separator: " • "))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "clock.arrow.circlepath")
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                        }
                        .buttonStyle(.plain)

                        if route.id != (viewModel?.recentRoutes.last?.id) {
                            Divider()
                                .padding(.leading, 16)
                        }
                    }
                }
                .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    var saveCurrentTripSheet: some View {
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
                    .disabled(viewModel?.hasCurrentPlan != true)
                }
            }
        }
    }

    private var defaultSavedTripName: String {
        let origin = viewModel?.originSnapshot()?.name ?? AppLocalization.localized("Origin")
        let destination = viewModel?.destinationSnapshot()?.name ?? AppLocalization.localized("Destination")
        return "\(origin) → \(destination)"
    }

    private func saveCurrentTrip() {
        // Prefer the city of the network that actually planned the current routes: the
        // provider picks its network by coordinates, so a seam trip (Foshan network under
        // a selected Guangzhou) must not be persisted under the selection.
        guard let city = plannerCity(forID: viewModel?.lastPlannedCityID) ?? appState.selectedCity,
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
