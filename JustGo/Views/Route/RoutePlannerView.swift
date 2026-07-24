import SwiftUI
import CoreLocation
import UIKit

/// Reports the inline suggestion list's top edge in `.global` space so its height cap can
/// track the keyboard's measured top (same pattern as Map/Station Search).
private struct SuggestionListTopYKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct RoutePlannerView: View {
    @Environment(DIContainer.self) private var container
    @Environment(AppState.self) var appState
    @Environment(TripMemoryService.self) var tripMemoryService
    @State var viewModel: RoutePlannerViewModel?
    @State var showResults = false
    @FocusState var focusedField: RouteInputField?
    @State private var showCityPicker = false
    @State var showSaveCurrentTrip = false
    @State var savedTripName = ""
    @State var scrollToTopTrigger = false
    @State private var resumableTrip: Route?
    @State private var showResumeLiveGo = false
    @State private var keyboardHeight: CGFloat = 0
    @State private var suggestionListTopY: CGFloat = 0
    // Raw theme hex for solid-fill buttons/banners below — `Color.accentColor` (the global
    // tint, set from `Color.adaptive(hex:)` in ContentView) lightens toward white in dark
    // mode for *foreground* legibility; used as a fill under white text that collapses
    // contrast instead, so those specific spots use this raw value.
    @AppStorage("selectedThemeHex") private var selectedThemeHex = AppTheme.forestGreen.rawValue

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 20) {
                            Color.clear.frame(height: 0).id("plannerTop")
                            if let resumableTrip { resumeTripBanner(resumableTrip) }
                            // Simplified UI (cognitive accessibility): only the essentials —
                            // city, the fields, and search. The resume banner stays: an
                            // active trip is never noise. Accessibility needs live in
                            // Profile → Accessibility Settings and seed the search directly.
                            citySelector
                            if !simplifiedUI { smartCommuteSection }
                            routeInputSection
                            plannerActionRail
                            if !simplifiedUI {
                                departurePlannerSection
                                savedTripsSection
                                recentRoutesSection
                            }
                        }
                        .padding()
                    }
                    .onChange(of: scrollToTopTrigger) { _, _ in
                        withAnimation { proxy.scrollTo("plannerTop", anchor: .top) }
                    }
                    // Pin the input card to the top whenever a field is active — centering
                    // the field wasted the space below it, squeezing the suggestion list.
                    // With the card at the top, the active field, its capped list, and the
                    // keyboard fit together even on small screens.
                    .onChange(of: activeSuggestions?.field) { _, field in
                        guard field != nil else { return }
                        withAnimation { proxy.scrollTo("routeInputCard", anchor: .top) }
                    }
                    .onChange(of: focusedField) { _, field in
                        guard field != nil else { return }
                        withAnimation { proxy.scrollTo("routeInputCard", anchor: .top) }
                    }
                    .onChange(of: keyboardHeight) { _, height in
                        guard height > 0, focusedField != nil else { return }
                        withAnimation { proxy.scrollTo("routeInputCard", anchor: .top) }
                    }
                }

            }
            .navigationTitle(AppLocalization.localized("Route Planner"))
            .navigationBarTitleDisplayMode(.large)
            .background(Color.appBackground)
            .onPreferenceChange(SuggestionListTopYKey.self) { suggestionListTopY = $0 }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
                guard let value = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue else { return }
                let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? TimeInterval ?? 0.25
                withAnimation(.easeInOut(duration: duration)) {
                    keyboardHeight = max(0, UIScreen.main.bounds.height - value.cgRectValue.origin.y)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { note in
                let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? TimeInterval ?? 0.25
                withAnimation(.easeInOut(duration: duration)) {
                    keyboardHeight = 0
                }
            }
            .sheet(isPresented: $showCityPicker) {
                CityPickerView(selectedCity: Binding(
                    get: { appState.selectedCity },
                    set: { appState.selectedCity = $0 }
                ))
            }
            .onChange(of: appState.selectedCity?.id) { _, newID in
                // switchPlannerCity applies the city to the view model synchronously, so
                // when this deferred onChange arrives with the VM already on the new city
                // it's that switch's echo — resetting showResults then would race the
                // saved-trip/quick-route flow and pop the results it just pushed.
                let isProgrammaticEcho = viewModel?.selectedCity?.id == newID
                viewModel?.cityChanged(to: appState.selectedCity)
                // A pushed results screen belongs to the previous city's search, whose
                // routes cityChanged just cleared — pop it rather than leave an empty
                // "0 routes" page for the user to come back to.
                if !isProgrammaticEcho { showResults = false }
            }
            .onChange(of: appState.accessibilityPreference.routeAffectingSignature) { _, _ in
                if viewModel?.syncAccessibilityPreference(appState.accessibilityPreference) == true {
                    showResults = false
                }
            }
            .navigationDestination(isPresented: $showResults) {
                if let viewModel = viewModel {
                    RouteResultsView(viewModel: viewModel)
                }
            }
            .onChange(of: appState.pendingRouteInput) { _, pending in
                applyPendingRouteInput(pending)
            }
            .sheet(isPresented: $showSaveCurrentTrip) {
                saveCurrentTripSheet
            }
            .fullScreenCover(isPresented: $showResumeLiveGo, onDismiss: {
                ActiveTripStore.clear()
                resumableTrip = nil
            }) {
                if let resumableTrip {
                    LiveGoView(route: resumableTrip)
                }
            }
        }
        .task {
            if viewModel == nil {
                viewModel = container.makeRoutePlannerViewModel()
            }
            if viewModel?.syncAccessibilityPreference(appState.accessibilityPreference) == true {
                showResults = false
            }
            viewModel?.cityChanged(to: appState.selectedCity)
            viewModel?.prewarmLocation()
            applyPendingRouteInput(appState.pendingRouteInput)
            resumableTrip = ActiveTripStore.load()
        }
    }

    @ViewBuilder
    private var departurePlannerSection: some View {
        if let viewModel {
            DeparturePlannerSection(anchor: Binding(
                get: { viewModel.tripAnchor },
                set: { viewModel.tripAnchor = $0 }
            ))
        }
    }

    private var citySelector: some View {
        Button(action: { showCityPicker = true }) {
            HStack {
                Image(systemName: "building.2.fill")
                    .foregroundStyle(Color.accentColor)
                Text(AppLocalization.localized("City"))
                Spacer()
                Text(appState.selectedCity?.localizedName ?? AppLocalization.localized("Select City"))
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var simplifiedUI: Bool {
        appState.accessibilityPreference.simplifiedUI
    }

    private func applyPendingRouteInput(_ pending: AppState.PendingRouteInput?) {
        guard let pending, let vm = viewModel else { return }
        // A station-originated input can reference another city (Quick Tags → station
        // detail → "From here"); a map POI names no city, so infer one when it's clearly
        // outside the selected city's area (the map pans freely across cities).
        switchPlannerCity(forPlaceCityID: pending.cityID, coordinate: pending.place.coordinate)
        vm.selectPlace(pending.place, for: pending.role)
        appState.pendingRouteInput = nil
    }

    /// Switches the app-wide city so a cross-city place (saved trip, quick tag)
    /// plans against its own network instead of the selected city's. Routes through
    /// cityChanged synchronously: the deferred selectedCity onChange then finds the view
    /// model already up to date and doesn't wipe the fields the caller fills next.
    func switchPlannerCity(toCityID cityID: String) {
        guard cityID != appState.selectedCity?.id,
              let city = container.cityService.getCity(byID: cityID) else { return }
        appState.selectedCity = city
        viewModel?.cityChanged(to: city)
    }

    /// City object for a pack cityID — lets the save-trip sheet persist the trip under
    /// the network that actually planned it, which can differ from the selection.
    func plannerCity(forID id: String?) -> City? {
        id.flatMap { container.cityService.getCity(byID: $0) }
    }

    /// City switch for a place that may not name its city (map POIs, legacy quick places).
    /// A known cityID is authoritative. Otherwise infer only when the coordinate is clearly
    /// outside the selected city's metro area (beyond the 80km suggestion-search radius):
    /// seam places in adjacent, interconnected metros (Guangzhou/Foshan) must keep the
    /// user's selected network, since nearest-city-center would misassign them.
    func switchPlannerCity(forPlaceCityID cityID: String?, coordinate: CLLocationCoordinate2D) {
        if let cityID {
            switchPlannerCity(toCityID: cityID)
            return
        }
        guard let selected = appState.selectedCity else { return }
        let place = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let selectedCenter = CLLocation(latitude: selected.coordinate.latitude, longitude: selected.coordinate.longitude)
        guard place.distance(from: selectedCenter) > 80_000,
              let nearest = container.cityService.findNearestCity(to: place),
              nearest.id != selected.id else { return }
        switchPlannerCity(toCityID: nearest.id)
    }

    private func resumeTripBanner(_ route: Route) -> some View {
        HStack(spacing: 12) {
            Button {
                showResumeLiveGo = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "figure.walk.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.white)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(AppLocalization.text(english: "Resume your trip", simplified: "继续您的行程", traditional: "繼續您的行程"))
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(.white)
                        Text("\(route.origin) → \(route.destination)")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                ActiveTripStore.clear()
                resumableTrip = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.white.opacity(0.85))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(AppLocalization.text(english: "Dismiss", simplified: "关闭", traditional: "關閉"))
        }
        .padding()
        .background(Color(hex: selectedThemeHex), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var plannerActionRail: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                if !simplifiedUI {
                    saveCurrentTripButton
                }
                searchButton
            }
        }
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

                    // Inline (in the card, directly under whichever field is active) rather
                    // than a floating overlay pinned at a fixed offset: the card's position
                    // varies with the sections above it, with scrolling, and with type size,
                    // so an overlay could cover the fields or detach entirely. Inline content
                    // also participates in the scroll view's keyboard avoidance.
                    VStack(spacing: 12) {
                        stationField(
                            placeholder: LocalizedStringKey(AppLocalization.localized("From")),
                            field: .origin
                        )
                        if let activeSuggestions, activeSuggestions.field == .origin {
                            suggestionDropdown(
                                suggestions: activeSuggestions.suggestions,
                                select: { viewModel?.selectPlace($0, for: .origin) }
                            )
                        }

                        stationField(
                            placeholder: LocalizedStringKey(AppLocalization.localized("To")),
                            field: .destination
                        )
                        if let activeSuggestions, activeSuggestions.field == .destination {
                            suggestionDropdown(
                                suggestions: activeSuggestions.suggestions,
                                select: { viewModel?.selectPlace($0, for: .destination) }
                            )
                        }
                    }
                }

                HStack(spacing: 8) {
                    quickTagRow
                    Button(action: { viewModel?.swapOriginDestination() }) {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.title3)
                            .foregroundStyle(Color.accentColor)
                            .padding(8)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .accessibilityLabel(AppLocalization.localized("Swap origin and destination"))
                }
            }
        }
        .id("routeInputCard")
    }

    /// One-tap fills under the From/To bars: current location plus Quick Tags.
    /// Fills the focused field, else the first empty one.
    private var quickTagRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                quickTagChip(
                    title: AppLocalization.localized("Current Location"),
                    icon: "location.fill"
                ) {
                    let field = quickTagTargetField
                    Task {
                        // Align the app to the city the device is in (bounded nearest-city
                        // rule) — filling a Beijing coordinate under a selected Shanghai
                        // otherwise leaves suggestions and name resolution keyed to the
                        // wrong city.
                        await viewModel?.useCurrentLocation(for: field) { coordinate in
                            switchPlannerCity(forPlaceCityID: nil, coordinate: coordinate)
                        }
                    }
                }

                ForEach(sortedQuickTags) { quickTag in
                    quickTagChip(title: quickTag.kind.title, icon: quickTag.kind.icon) {
                        fillField(with: quickTag)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    /// Home, then Work, then custom tags in saved order (explicit buckets — no
    /// reliance on sort stability).
    private var sortedQuickTags: [StationQuickTag] {
        let quickTags = tripMemoryService.stationQuickTags
        let customs = quickTags.filter {
            if case .custom = $0.kind { return true }
            return false
        }
        return quickTags.filter { $0.kind == .home }
            + quickTags.filter { $0.kind == .work }
            + customs
    }

    private var quickTagTargetField: RouteInputField {
        focusedField
            ?? ((viewModel?.name(for: .origin).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                ? .origin
                : .destination)
    }

    private func fillField(with quickTag: StationQuickTag) {
        // Capture the target before the city switch: a cross-city quick tag wipes the
        // fields when the planner realigns to its network.
        let field = quickTagTargetField
        let coordinate = CLLocationCoordinate2D(latitude: quickTag.latitude, longitude: quickTag.longitude)
        switchPlannerCity(forPlaceCityID: quickTag.cityID, coordinate: coordinate)
        viewModel?.selectPlace(
            quickTag.transitPlace,
            for: field
        )
    }

    private func quickTagChip(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption)
                Text(title)
                    .font(.caption)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.accentColor.opacity(0.12), in: Capsule())
            .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
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
            .background(Color.appSurfaceSecondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // Both measured in `.global` (matching UIScreen bounds), so no coordinate conversion.
    // The floor keeps a couple of rows usable in pathological layouts; the ceiling keeps
    // the list from dwarfing the card when no keyboard is on screen (hardware keyboard).
    private var suggestionMaxHeight: CGFloat {
        guard suggestionListTopY > 0 else { return keyboardHeight > 0 ? 0 : 260 }
        let keyboardTopY = UIScreen.main.bounds.height - keyboardHeight
        let available = max(0, keyboardTopY - suggestionListTopY - 12)
        return keyboardHeight > 0 ? available : min(320, max(96, available))
    }

    private func suggestionDropdown(
        suggestions: [TransitPlace],
        select: @escaping (TransitPlace) -> Void
    ) -> some View {
        ScrollView {
            suggestionRows(suggestions: suggestions, select: select)
        }
        .scrollBounceBehavior(.basedOnSize)
        // Capped at the keyboard's measured top edge so the field group, the list, and
        // the keyboard stay simultaneously visible; taller lists scroll internally.
        .frame(maxHeight: suggestionMaxHeight)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: SuggestionListTopYKey.self, value: proxy.frame(in: .global).minY)
            }
        }
    }

    private func suggestionRows(
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
    }

    private var searchButton: some View {
        Button(action: {
            Task {
                // Push only when THIS search published; never set false here — a
                // superseded continuation must not pop the owning search's results.
                if await viewModel?.searchRoutes() == true {
                    showResults = true
                }
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
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(viewModel?.canSearch == true ? Color(hex: selectedThemeHex) : Color.gray)
            .foregroundStyle(.white)
            .clipShape(Capsule())
        }
        .disabled(viewModel?.canSearch != true || viewModel?.isLoading == true)
        .alert(AppLocalization.localized("No Routes Found"), isPresented: errorAlertIsPresented) {
            Button(AppLocalization.localized("OK"), role: .cancel) {}
        } message: {
            Text(viewModel?.errorMessage ?? "")
        }
    }
}
