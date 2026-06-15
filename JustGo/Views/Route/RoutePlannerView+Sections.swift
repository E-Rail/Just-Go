import SwiftUI

extension RoutePlannerView {
    var quickTagsSection: some View {
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
        focusedField ?? ((viewModel?.originName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) ? .origin : .destination)
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
        .disabled(viewModel?.canSearch != true)
        .opacity(viewModel?.canSearch == true ? 1 : 0.55)
    }

    var recentRoutesSection: some View {
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
