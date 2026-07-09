import SwiftUI

extension RoutePlannerView {
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
            Label(AppLocalization.localized("Save"), systemImage: "bookmark")
                .font(.subheadline)
                .fontWeight(.medium)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(height: 48)
                .background(Color(.systemGray5), in: RoundedRectangle(cornerRadius: 10))
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
