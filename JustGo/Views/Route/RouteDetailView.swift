import SwiftUI

struct RouteDetailView: View {
    private let initialRoute: Route
    let preference: RoutePreference
    let alternatives: [Route]
    @State private var selectedRouteID: UUID
    @State private var showRouteReport = false
    @State private var showTripNote = false
    @State private var showExpandedRouteMap = false
    @State private var tripNote = ""
    @State private var routeReportNote = ""
    @State private var routeReportSeverity: AccessibilityReportSeverity = .medium
    @Environment(DIContainer.self) private var container
    @Environment(AppState.self) private var appState
    @Environment(TripMemoryService.self) private var tripMemoryService
    @Environment(AccessibilityReportService.self) private var accessibilityReportService

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
            FullScreenRouteMapView(route: route)
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

    private var route: Route {
        alternatives.first { $0.id == selectedRouteID } ?? initialRoute
    }

    private var routeMapPreview: some View {
        TransitMapView(
            visibleRegion: .constant(route.previewRegion),
            stations: [],
            subwayLines: [],
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
                    StatItem(title: "Duration", value: route.formattedDuration, icon: "clock")
                    StatItem(title: "Stops", value: "\(route.totalStops)", icon: "tram")
                    StatItem(title: "Transfers", value: "\(route.transferCount)", icon: "arrow.triangle.2.circlepath")
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

    private var routeFeasibilityCard: some View {
        let feasibility = currentFeasibility
        return GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(feasibility.title, systemImage: feasibility.level.iconName)
                        .font(.headline)
                        .foregroundStyle(feasibility.level.color)
                    Spacer()
                    if feasibility.estimatedExtraMinutes > 0 {
                        Text(AppLocalization.text(
                            english: "+\(feasibility.estimatedExtraMinutes) min possible",
                            chinese: "可能增加\(feasibility.estimatedExtraMinutes)分钟"
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                if let bottleneck = feasibility.bottleneck {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(AppLocalization.localized("Bottleneck"))
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text("\(bottleneck.segmentTitle): \(bottleneck.reason)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                ForEach(feasibility.allExplanations.prefix(4), id: \.self) { explanation in
                    Label(explanation, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if feasibility.allExplanations.isEmpty {
                    Text(AppLocalization.localized("No accessibility concerns found from available data."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var tripConfidenceCard: some View {
        TripConfidenceCard(confidence: currentConfidence)
    }

    @ViewBuilder
    private var accessGuidanceCard: some View {
        if !route.accessGuidance.isEmpty {
            GlassCard {
                VStack(alignment: .leading, spacing: 14) {
                    Text(AppLocalization.localized("Access Guidance"))
                        .font(.headline)

                    ForEach(route.accessGuidance) { guide in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: guide.kind == .origin ? "arrow.down.forward.circle.fill" : "arrow.up.forward.circle.fill")
                                    .font(.title3)
                                    .foregroundStyle(.blue)
                                    .frame(width: 26)

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(guide.title)
                                        .font(.subheadline)
                                        .fontWeight(.semibold)
                                    Text(guide.primaryInstruction)
                                        .font(.subheadline)
                                    Text(guide.formattedWalk)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            ForEach(guide.accessibilityNotes, id: \.self) { note in
                                Label(note, systemImage: "info.circle")
                                    .font(.caption)
                                    .foregroundStyle(.blue)
                            }

                            if let firstStep = guide.walkingSteps.first {
                                Text(firstStep.instruction)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 36)
                            }
                        }

                        if guide.id != route.accessGuidance.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private var segmentsTimeline: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                Text(AppLocalization.localized("Route Steps"))
                    .font(.headline)

                ForEach(Array(route.segments.enumerated()), id: \.element.id) { index, segment in
                    segmentTimelineRow(segment, isLast: index == route.segments.count - 1)
                }
            }
        }
    }

    private func segmentTimelineRow(_ segment: RouteSegment, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack {
                segmentIcon(segment)
                if !isLast {
                    Rectangle()
                        .fill(segmentColor(segment).opacity(0.65))
                        .frame(width: 2, height: 20)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(segment.summaryLabel)
                    .font(.body)
                    .fontWeight(.medium)

                if let from = segment.fromStationName, let to = segment.toStationName {
                    Text("\(from) → \(to)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if segment.duration >= 60 {
                    Text(segment.formattedDuration)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let firstDirection = segment.walkingDirections?.first?.instruction,
                   segment.type == .walking {
                    Text(firstDirection)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ForEach(segment.accessibilityNotes, id: \.self) { note in
                    HStack(spacing: 4) {
                        Image(systemName: "info.circle")
                            .font(.caption)
                        Text(note)
                            .font(.caption)
                    }
                    .foregroundStyle(.blue)
                }
            }

            Spacer()
        }
    }

    private func segmentIcon(_ segment: RouteSegment) -> some View {
        Group {
            switch segment.type {
            case .walking:
                Image(systemName: "figure.walk")
                    .foregroundStyle(segmentColor(segment))
                    .padding(6)
                    .background(Color.gray.opacity(0.2), in: Circle())
            case .subway:
                Image(systemName: "tram.fill")
                    .foregroundStyle(segmentColor(segment))
                    .padding(6)
                    .background(Color(hex: segment.lineColorHex ?? "#000000").opacity(0.2), in: Circle())
            case .transfer:
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(segmentColor(segment))
                    .padding(6)
                    .background(Color.orange.opacity(0.2), in: Circle())
            }
        }
    }

    private func segmentColor(_ segment: RouteSegment) -> Color {
        switch segment.type {
        case .walking:
            return .gray
        case .subway:
            return Color(hex: segment.lineColorHex ?? "#007AFF")
        case .transfer:
            return .orange
        }
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

    private var routeReportSheet: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(AppLocalization.localized("Severity"), selection: $routeReportSeverity) {
                        ForEach(AccessibilityReportSeverity.allCases, id: \.self) { severity in
                            Text(severity.title).tag(severity)
                        }
                    }

                    TextEditor(text: $routeReportNote)
                        .frame(minHeight: 120)
                } header: {
                    Text(AppLocalization.localized("Route Issue"))
                } footer: {
                    Text(AppLocalization.localized("This stays on your device and affects your own route warnings."))
                }
            }
            .navigationTitle(AppLocalization.localized("Report Route Issue"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLocalization.localized("Cancel")) { showRouteReport = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppLocalization.localized("Save")) {
                        accessibilityReportService.createRouteReport(
                            cityID: appState.selectedCity?.id ?? "",
                            route: route,
                            status: .note,
                            severity: routeReportSeverity,
                            note: routeReportNote
                        )
                        showRouteReport = false
                    }
                    .disabled(routeReportNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private var tripNoteSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $tripNote)
                        .frame(minHeight: 120)
                } header: {
                    Text(AppLocalization.localized("Trip Note"))
                } footer: {
                    Text(AppLocalization.localized("Trip history is stored locally on this device."))
                }
            }
            .navigationTitle(AppLocalization.localized("Complete Trip"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLocalization.localized("Cancel")) { showTripNote = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppLocalization.localized("Save")) {
                        tripMemoryService.markTripComplete(
                            route: route,
                            cityID: appState.selectedCity?.id ?? "",
                            note: tripNote
                        )
                        showTripNote = false
                    }
                }
            }
        }
    }

    private var currentFeasibility: RouteFeasibility {
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
            alternatives: alternatives.isEmpty ? [route] : alternatives
        )
    }
}

private struct TripConfidenceCard: View {
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
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(confidence.score) / 100")
                            .font(.title3)
                            .fontWeight(.bold)
                        Text(confidence.level.title)
                            .font(.caption)
                            .foregroundStyle(confidence.level.color)
                    }
                    .accessibilityLabel("\(confidence.level.title), \(confidence.score) \(AppLocalization.localized("out of 100"))")
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

private struct FullScreenRouteMapView: View {
    let route: Route
    @Environment(\.dismiss) private var dismiss
    @State private var visibleRegion: MapVisibleRegion?

    init(route: Route) {
        self.route = route
        _visibleRegion = State(initialValue: route.previewRegion)
    }

    var body: some View {
        NavigationStack {
            TransitMapView(
                visibleRegion: $visibleRegion,
                stations: [],
                subwayLines: [],
                route: route,
                showsUserLocation: false,
                onRegionChanged: nil,
                onStationSelected: { _ in }
            )
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(AppLocalization.localized("Route Map"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                    }
                    .accessibilityLabel(AppLocalization.localized("Close route map"))
                }
            }
        }
    }
}

struct StatItem: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
            Text(AppLocalization.localized(title))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

private extension RouteFeasibilityLevel {
    var color: Color {
        switch self {
        case .good:
            return .green
        case .caution:
            return .orange
        case .risky:
            return .red
        case .unknown:
            return .gray
        }
    }

    var iconName: String {
        switch self {
        case .good:
            return "checkmark.circle.fill"
        case .caution:
            return "exclamationmark.triangle.fill"
        case .risky:
            return "xmark.octagon.fill"
        case .unknown:
            return "questionmark.circle.fill"
        }
    }
}

private extension RouteConfidenceLevel {
    var color: Color {
        switch self {
        case .high: return .green
        case .medium: return .orange
        case .low: return .red
        }
    }
}
