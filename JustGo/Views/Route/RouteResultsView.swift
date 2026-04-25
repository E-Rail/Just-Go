import SwiftUI

struct RouteResultsView: View {
    @Bindable var viewModel: RoutePlannerViewModel
    @State private var selectedRoute: Route?
    @State private var showRouteDetail = false

    var body: some View {
        List {
            sortOptionsSection

            if viewModel.isLoading {
                HStack {
                    Spacer()
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Finding routes...")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    Spacer()
                }
            } else if let error = viewModel.errorMessage {
                ContentUnavailableView {
                    Label("No Routes Found", systemImage: "map")
                } description: {
                    Text(error)
                }
            } else {
                routesSection
            }
        }
        .navigationTitle("Routes")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showRouteDetail) {
            if let route = selectedRoute {
                RouteDetailView(route: route)
            }
        }
    }

    private var sortOptionsSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    SortChip(title: "Fastest", icon: "clock", isSelected: viewModel.sortStrategy == .fastest) {
                        viewModel.sortStrategy = .fastest
                        viewModel.sortRoutes()
                    }
                    SortChip(title: "Fewest Transfers", icon: "arrow.triangle.swap", isSelected: viewModel.sortStrategy == .fewestTransfers) {
                        viewModel.sortStrategy = .fewestTransfers
                        viewModel.sortRoutes()
                    }
                    SortChip(title: "Most Accessible", icon: "accessibility", isSelected: viewModel.sortStrategy == .mostAccessible) {
                        viewModel.sortStrategy = .mostAccessible
                        viewModel.sortRoutes()
                    }
                    SortChip(title: "Fewest Stops", icon: "number", isSelected: viewModel.sortStrategy == .fewestStops) {
                        viewModel.sortStrategy = .fewestStops
                        viewModel.sortRoutes()
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var routesSection: some View {
        Section {
            ForEach(viewModel.routes) { route in
                RouteCard(route: route) {
                    selectedRoute = route
                    showRouteDetail = true
                }
            }
        }
    }
}

struct SortChip: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption)
                Text(title)
                    .font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? Color.blue : Color(.systemGray5))
            .foregroundStyle(isSelected ? .white : .primary)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct RouteCard: View {
    let route: Route
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(route.formattedDuration)
                            .font(.title2)
                            .fontWeight(.bold)
                        Text("\(route.formattedStops) • \(route.formattedTransfers)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if route.isFullyAccessible {
                        HStack(spacing: 4) {
                            Image(systemName: "figure.roll")
                            Text("Accessible")
                        }
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.green.opacity(0.2), in: Capsule())
                        .foregroundStyle(.green)
                    }
                }

                // Route segments preview
                HStack(spacing: 2) {
                    ForEach(route.segments) { segment in
                        segmentBar(segment)
                    }
                }
                .frame(height: 4)
                .clipShape(Capsule())

                // Segment details
                ForEach(route.segments) { segment in
                    segmentDetail(segment)
                }

                // Warnings
                if !route.warnings.isEmpty {
                    ForEach(route.warnings) { warning in
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text(warning.message)
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
            .padding()
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private func segmentBar(_ segment: RouteSegment) -> some View {
        Group {
            switch segment.type {
            case .walking:
                Color.gray
            case .subway:
                Color(hex: segment.lineColorHex ?? "#000000")
            case .transfer:
                Color.orange
            }
        }
        .frame(minWidth: segment.type == .walking ? 20 : 40)
    }

    private func segmentDetail(_ segment: RouteSegment) -> some View {
        HStack(spacing: 8) {
            segmentIcon(segment)

            VStack(alignment: .leading, spacing: 2) {
                Text(segmentLabel(segment))
                    .font(.subheadline)
                    .fontWeight(.medium)

                if let notes = segment.accessibilityNotes.first {
                    Text(notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Text(segment.formattedDuration)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func segmentIcon(_ segment: RouteSegment) -> some View {
        Group {
            switch segment.type {
            case .walking:
                Image(systemName: "figure.walk")
                    .foregroundStyle(.gray)
            case .subway:
                Image(systemName: "tram.fill")
                    .foregroundStyle(Color(hex: segment.lineColorHex ?? "#000000"))
            case .transfer:
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption)
        .frame(width: 20)
    }

    private func segmentLabel(_ segment: RouteSegment) -> String {
        switch segment.type {
        case .walking:
            return "Walk \(Int(segment.duration / 60)) min"
        case .subway:
            return "\(segment.lineName ?? "Subway") • \(segment.stops) stops"
        case .transfer:
            return "Transfer"
        }
    }
}
