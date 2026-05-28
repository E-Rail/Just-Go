import SwiftUI

struct StationDetailView: View {
    let station: Station
    @Environment(DIContainer.self) private var container
    @State private var viewModel: StationDetailViewModel?
    @State private var selectedStationImage: FullScreenStationImage?
    @Environment(AccessibilityService.self) private var accessibilityService

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                stationHeader
                linesSection
                accessibilitySection
                arrivalsSection
                serviceStatusSection
                stationMapSection
            }
            .padding()
        }
        .navigationTitle(displayedStation.localizedName)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            viewModel = StationDetailViewModel(aMapService: container.aMapService)
            viewModel?.loadStation(station)
            await viewModel?.loadCityPack()
            await viewModel?.loadTrainTimes()
        }
        .fullScreenCover(item: $selectedStationImage) { image in
            FullScreenStationImageView(image: image)
        }
    }

    private var stationHeader: some View {
        let station = displayedStation
        return GlassCard {
            VStack(spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(station.localizedName)
                            .font(.title)
                            .fontWeight(.bold)
                        if let alternateName = station.alternateLocalizedName {
                            Text(alternateName)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    if station.isTransferStation {
                        Text(AppLocalization.localized("Transfer"))
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.orange.opacity(0.2), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                }

                if station.accessibility?.summary == .fullyAccessible {
                    HStack {
                        Image(systemName: "figure.roll")
                            .foregroundStyle(.green)
                        Text(AppLocalization.localized("Fully Accessible Station"))
                            .font(.subheadline)
                            .foregroundStyle(.green)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private var linesSection: some View {
        let station = displayedStation
        return GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(AppLocalization.localized("Lines"))
                    .font(.headline)

                ForEach(station.lines) { line in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color(hex: line.colorHex))
                            .frame(width: 12, height: 12)
                        Text(line.localizedName)
                            .font(.body)
                        if let alternateName = line.alternateLocalizedName {
                            Text(alternateName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var accessibilitySection: some View {
        let station = displayedStation
        return GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(AppLocalization.localized("Accessibility"))
                    .font(.headline)

                if let accessibility = station.accessibility {
                    accessibilitySummary(accessibility)

                    if accessibility.hasVerifiedAccessibilityData {
                        verifiedAccessibilitySections(accessibility)

                        if accessibility.hasUnverifiedCoreAccessibilityData {
                            Text(AppLocalization.localized("Some facilities are not verified"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if accessibility.dataSource == "beijing_official" {
                            accessibilitySourceNote(accessibility)
                        }
                    } else {
                        accessibilitySourceNote(accessibility)
                    }
                } else {
                    accessibilityUnverifiedNote
                }
            }
        }
    }

    @ViewBuilder
    private func verifiedAccessibilitySections(_ accessibility: StationAccessibility) -> some View {
        if accessibility.hasMobilityRows {
            VStack(alignment: .leading, spacing: 8) {
                Text(AppLocalization.localized("Mobility"))
                    .font(.subheadline)
                    .fontWeight(.medium)

                if accessibility.elevatorAvailability != .unknown || !accessibility.elevatorLocations.isEmpty {
                    accessibilityRow(
                        icon: "arrow.up.arrow.down.circle.fill",
                        title: "Elevator",
                        subtitle: detailText(accessibility.elevatorLocations, fallback: accessibility.elevatorAvailability.localizedStatusText),
                        status: AccessibilityStatus(accessibility.elevatorAvailability)
                    )
                }

                if accessibility.wheelchairRampAvailability != .unknown || !accessibility.accessibleEntrances.isEmpty {
                    accessibilityRow(
                        icon: "figure.roll",
                        title: "Wheelchair Ramp",
                        subtitle: detailText(accessibility.accessibleEntrances, fallback: accessibility.wheelchairRampAvailability.localizedStatusText),
                        status: AccessibilityStatus(accessibility.wheelchairRampAvailability)
                    )
                }

                if accessibility.escalatorAvailability != .unknown {
                    accessibilityRow(
                        icon: "arrow.up.to.line",
                        title: "Escalator",
                        subtitle: accessibility.escalatorAvailability.localizedStatusText,
                        status: AccessibilityStatus(accessibility.escalatorAvailability)
                    )
                }
            }
        }

        if accessibility.hasVisionRows {
            VStack(alignment: .leading, spacing: 8) {
                Text(AppLocalization.localized("Vision"))
                    .font(.subheadline)
                    .fontWeight(.medium)

                if accessibility.tactilePathAvailability != .unknown {
                    accessibilityRow(
                        icon: "hand.raised.fill",
                        title: "Tactile Path",
                        subtitle: tactilePathDetail(accessibility),
                        status: AccessibilityStatus(accessibility.tactilePathAvailability)
                    )
                }

                if accessibility.audioAnnouncementAvailability != .unknown {
                    accessibilityRow(
                        icon: "speaker.wave.2.fill",
                        title: "Audio Announcement",
                        subtitle: accessibility.audioAnnouncementAvailability.localizedStatusText,
                        status: AccessibilityStatus(accessibility.audioAnnouncementAvailability)
                    )
                }
            }
        }

        if accessibility.hasFacilityRows {
            VStack(alignment: .leading, spacing: 8) {
                Text(AppLocalization.localized("Station Facilities"))
                    .font(.subheadline)
                    .fontWeight(.medium)

                if accessibility.accessibleRestroomAvailability != .unknown {
                    accessibilityRow(
                        icon: "figure.roll",
                        title: "Accessible Restroom",
                        subtitle: accessibility.accessibleRestroomAvailability.localizedStatusText,
                        status: AccessibilityStatus(accessibility.accessibleRestroomAvailability)
                    )
                }

                ForEach(accessibility.facilityNotes, id: \.self) { note in
                    Label(note, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }

        if accessibility.hasHearingRows {
            VStack(alignment: .leading, spacing: 8) {
                Text(AppLocalization.localized("Hearing"))
                    .font(.subheadline)
                    .fontWeight(.medium)

                if accessibility.visualAnnouncementAvailability != .unknown {
                    accessibilityRow(
                        icon: "eye.fill",
                        title: "Visual Display",
                        subtitle: accessibility.visualAnnouncementAvailability.localizedStatusText,
                        status: AccessibilityStatus(accessibility.visualAnnouncementAvailability)
                    )
                }
            }
        }
    }

    private var accessibilityUnverifiedNote: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(AppLocalization.localized("Accessibility not verified"))
                .font(.subheadline)
                .fontWeight(.medium)
            Text(AppLocalization.localized("AMap does not provide station accessibility status; no local verification is available."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func accessibilitySourceNote(_ accessibility: StationAccessibility) -> some View {
        let message: String
        if accessibility.dataSource == "beijing_official" {
            message = AppLocalization.localized("Accessibility information from official Beijing Subway data.")
        } else if accessibility.dataSource?.contains("_official") == true ||
            accessibility.dataSource?.contains("official") == true {
            message = AppLocalization.localized("Accessibility information from official city data.")
        } else {
            message = AppLocalization.localized("AMap does not provide station accessibility status; no local verification is available.")
        }
        return Text(message)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func accessibilitySummary(_ accessibility: StationAccessibility) -> some View {
        HStack(spacing: 10) {
            Image(systemName: accessibility.summary.iconName)
                .foregroundStyle(accessibility.summary.color)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(AppLocalization.localized(accessibility.summary.titleKey))
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(AppLocalization.localized(accessibility.summary.descriptionKey))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func accessibilityRow(icon: String, title: String, subtitle: String, status: AccessibilityStatus) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(status.color)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(AppLocalization.localized(title))
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(AppLocalization.localized(subtitle))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Circle()
                .fill(status.color)
                .frame(width: 8, height: 8)
        }
    }

    private func detailText(_ details: [String], fallback: String) -> String {
        let text = details.joined(separator: ", ").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? fallback : text
    }

    private func tactilePathDetail(_ accessibility: StationAccessibility) -> String {
        guard accessibility.tactilePathAvailability == .available else {
            return accessibility.tactilePathAvailability.localizedStatusText
        }
        guard accessibility.tactilePathCoverage > 0 else {
            return AppLocalization.localized("Tactile path available")
        }
        return AppLocalization.text(
            english: "Coverage: \(Int(accessibility.tactilePathCoverage * 100))%",
            chinese: "覆盖率：\(Int(accessibility.tactilePathCoverage * 100))%"
        )
    }

    private var arrivalsSection: some View {
        let arrivals = viewModel?.arrivals ?? []
        let timetableAssets = viewModel?.timetableAssets ?? []
        return GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(AppLocalization.localized("Train Times"))
                    .font(.headline)

                if viewModel?.isLoading == true {
                    ProgressView()
                } else if arrivals.isEmpty && timetableAssets.isEmpty {
                    Text(viewModel?.errorMessage ?? AppLocalization.localized("Schedule unavailable"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(arrivals) { arrival in
                        ArrivalCountdown(arrival: arrival)
                    }

                    if timetableAssets.isEmpty == false {
                        Text(AppLocalization.localized("Official Timetable Images"))
                            .font(.subheadline)
                            .fontWeight(.medium)
                        ForEach(timetableAssets, id: \.assetURL) { asset in
                            stationAssetContent(
                                asset,
                                defaultTitle: AppLocalization.localized("Official timetable image")
                            )
                        }
                    }

                    if let statusMessage = viewModel?.trainTimeStatusMessage {
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if arrivals.contains(where: \.hasLiveCountdown) == false {
                        Text(AppLocalization.localized("Shows first/last train times, not live arrival countdowns."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var stationMapSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(AppLocalization.localized("Station Map"))
                    .font(.headline)

                if viewModel?.isLoadingCityPack == true {
                    ProgressView()
                } else if let stationMap = viewModel?.stationMap {
                    stationMapContent(stationMap)
                } else {
                    Text(AppLocalization.localized("Official 3D station map not collected yet"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let statusMessage = viewModel?.stationMapStatusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var serviceStatusSection: some View {
        if let status = viewModel?.serviceStatus, status.hasDisplayableStatus {
            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text(AppLocalization.localized("Station Status"))
                        .font(.headline)

                    if let statusColor = status.statusColor, statusColor.isEmpty == false {
                        Text(AppLocalization.text(
                            english: "Official live station status: \(statusColor)",
                            chinese: "官方实时车站状态：\(localizedStatusColor(statusColor))"
                        ))
                        .font(.subheadline)
                    }

                    ForEach(status.crowdControlWindows, id: \.self) { window in
                        Text(AppLocalization.text(
                            english: "Crowd-control window: \(window)",
                            chinese: "限流时段：\(window)"
                        ))
                        .font(.subheadline)
                    }

                    Text(AppLocalization.localized("Status data is from Beijing Subway official web map, not train arrival countdowns."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func stationMapContent(_ stationMap: CityPackStationMap) -> some View {
        if stationMap.isImage, let url = stationMap.resolvedURL {
            remoteImage(
                url: url,
                title: stationMap.title ?? AppLocalization.localized("Station Map")
            )

            Link(stationMap.title ?? AppLocalization.localized("Open station map"), destination: url)
                .font(.caption)
                .foregroundStyle(.blue)
        } else if let url = stationMap.resolvedURL {
            Link(stationMap.title ?? AppLocalization.localized("Open station map"), destination: url)
                .font(.subheadline)
        } else {
            Text(AppLocalization.localized("Station map could not be loaded"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func stationAssetContent(_ asset: CityPackStationAsset, defaultTitle: String) -> some View {
        if asset.isImage, let url = asset.resolvedURL {
            VStack(alignment: .leading, spacing: 6) {
                Text(asset.title ?? defaultTitle)
                    .font(.subheadline)
                    .fontWeight(.medium)
                remoteImage(
                    url: url,
                    title: asset.title ?? defaultTitle
                )
                Link(AppLocalization.localized("Open official timetable image"), destination: url)
                    .font(.caption)
                    .foregroundStyle(.blue)
            }
        }
    }

    @ViewBuilder
    private func remoteImage(url: URL, title: String) -> some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                Button {
                    selectedStationImage = FullScreenStationImage(url: url, title: title)
                } label: {
                    image
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 160)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(alignment: .topTrailing) {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(.white)
                                .padding(8)
                                .background(.black.opacity(0.55), in: Circle())
                                .padding(8)
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 1)
                        }
                    }
                .buttonStyle(.plain)
                .accessibilityLabel(AppLocalization.localized("Open station image full screen"))
            case .failure:
                Text(AppLocalization.localized("Station map could not be loaded"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            case .empty:
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 160)
            @unknown default:
                EmptyView()
            }
        }
    }

    private func localizedStatusColor(_ color: String) -> String {
        switch color.lowercased() {
        case "green":
            return AppLocalization.text(english: "green", chinese: "绿色")
        case "yellow":
            return AppLocalization.text(english: "yellow", chinese: "黄色")
        case "red":
            return AppLocalization.text(english: "red", chinese: "红色")
        case "black":
            return AppLocalization.text(english: "black", chinese: "黑色")
        default:
            return color
        }
    }

    private var displayedStation: Station {
        viewModel?.station ?? station
    }
}

private struct FullScreenStationImage: Identifiable {
    let url: URL
    let title: String

    var id: String {
        url.absoluteString
    }
}

private struct FullScreenStationImageView: View {
    let image: FullScreenStationImage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                AsyncImage(url: image.url) { phase in
                    switch phase {
                    case .success(let loadedImage):
                        loadedImage
                            .resizable()
                            .scaledToFit()
                            .padding()
                    case .failure:
                        ContentUnavailableView(
                            AppLocalization.localized("Station map could not be loaded"),
                            systemImage: "exclamationmark.triangle"
                        )
                        .foregroundStyle(.white)
                    case .empty:
                        ProgressView()
                            .tint(.white)
                    @unknown default:
                        EmptyView()
                    }
                }
            }
            .navigationTitle(image.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                    }
                    .foregroundStyle(.white)
                    .accessibilityLabel(AppLocalization.localized("Close station image"))
                }
            }
        }
    }
}

private extension StationAccessibility {
    var hasMobilityRows: Bool {
        elevatorAvailability != .unknown ||
            !elevatorLocations.isEmpty ||
            wheelchairRampAvailability != .unknown ||
            !accessibleEntrances.isEmpty ||
            escalatorAvailability != .unknown
    }

    var hasVisionRows: Bool {
        tactilePathAvailability != .unknown ||
            audioAnnouncementAvailability != .unknown
    }

    var hasHearingRows: Bool {
        visualAnnouncementAvailability != .unknown
    }

    var hasFacilityRows: Bool {
        accessibleRestroomAvailability != .unknown || !facilityNotes.isEmpty
    }
}

enum AccessibilityStatus {
    case available
    case unavailable
    case unknown

    init(_ availability: AccessibilityAvailability) {
        switch availability {
        case .available:
            self = .available
        case .unavailable:
            self = .unavailable
        case .unknown:
            self = .unknown
        }
    }

    var color: Color {
        switch self {
        case .available:
            return .green
        case .unavailable:
            return .red
        case .unknown:
            return .gray
        }
    }
}

private extension StationAccessibilitySummary {
    var titleKey: String {
        switch self {
        case .fullyAccessible:
            return "Fully Accessible"
        case .partial:
            return "Partial Accessibility"
        case .notVerified:
            return "Accessibility not verified"
        }
    }

    var descriptionKey: String {
        switch self {
        case .fullyAccessible:
            return "Station accessibility data is verified"
        case .partial:
            return "Some accessibility features are verified"
        case .notVerified:
            return "Station accessibility data is missing"
        }
    }

    var iconName: String {
        switch self {
        case .fullyAccessible:
            return "checkmark.circle.fill"
        case .partial:
            return "info.circle.fill"
        case .notVerified:
            return "questionmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .fullyAccessible:
            return .green
        case .partial:
            return .orange
        case .notVerified:
            return .gray
        }
    }
}
