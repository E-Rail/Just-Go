import MapKit
import SwiftUI

/// One street an operator lists against its exits, with every exit that reaches it.
struct OfficialStationExitStreet: Identifiable {
    let name: String
    let exits: [OfficialStationExitInformation]

    var id: String { name }
}

extension StationDetailView {
    /// The categories the loaded snapshot actually has data for — so a lines-only source
    /// (Guangzhou) shows just its trains with no empty Exits/Facilities tabs, and the segmented
    /// control appears only when there is more than one thing to switch between.
    private var officialInformationCategories: [OfficialStationInformationCategory] {
        guard let snapshot = viewModel?.officialStationInformation else { return [] }
        var categories: [OfficialStationInformationCategory] = []
        if !snapshot.lines.isEmpty { categories.append(.firstLast) }
        if !snapshot.exits.isEmpty { categories.append(.exits) }
        if !snapshot.facilityGroups.isEmpty { categories.append(.facilities) }
        return categories
    }

    /// The category to render: the picked one while it still has data, otherwise the first that does.
    private var effectiveOfficialInformationCategory: OfficialStationInformationCategory {
        let categories = officialInformationCategories
        if categories.contains(selectedOfficialInformationCategory) {
            return selectedOfficialInformationCategory
        }
        return categories.first ?? selectedOfficialInformationCategory
    }

    @ViewBuilder
    var officialStationInformationSection: some View {
        if usesNativeStationInformationSurface || viewModel?.officialResourceReview != nil {
            let review = viewModel?.officialResourceReview
            let resource = viewModel?.officialStationInformationSourceResource
            let contextResources = review?.resources.filter { $0.kind != .stationInformation } ?? []
            let provider = viewModel?.officialStationInformation?.source.title
                ?? resource?.provider
                ?? contextResources.first?.provider
                ?? AppLocalization.text(
                    english: "Reviewed official sources",
                    simplified: "已审核官方来源",
                    traditional: "已審核官方來源"
                )
            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(AppLocalization.text(
                                english: "Official Station Information",
                                simplified: "官方车站信息",
                                traditional: "官方車站資訊"
                            ))
                            .font(.headline)
                            Text(provider)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        DataConfidenceChip(
                            confidence: officialStationInformationConfidence(
                                review?.stationInformationStatus,
                                cityID: displayedStation.cityID
                            ),
                            compact: true
                        )
                    }

                    if usesNativeStationInformationSurface {
                        let categories = officialInformationCategories
                        if categories.count > 1 {
                            Picker(
                                AppLocalization.text(
                                    english: "Station information category",
                                    simplified: "车站信息类别",
                                    traditional: "車站資訊類別"
                                ),
                                selection: $selectedOfficialInformationCategory
                            ) {
                                ForEach(categories) { category in
                                    Text(category.title(for: displayedStation.cityID))
                                        .tag(category)
                                }
                            }
                            .pickerStyle(.segmented)
                        }

                        nativeOfficialStationInformationContent

                        if let resource {
                            Divider()
                            OfficialTransitResourceButton(resource: resource)
                        }

                        Text(officialStationInformationProvenance)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    } else if viewModel == nil || viewModel?.isLoadingCityPack == true {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(AppLocalization.text(
                                english: "Matching this station to the official directory",
                                simplified: "正在匹配官方车站目录",
                                traditional: "正在比對官方車站目錄"
                            ))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        }
                    } else if let review {
                        Label {
                            Text(officialStationInformationStatusText(review.stationInformationStatus))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        } icon: {
                            Image(systemName: "info.circle")
                                .foregroundStyle(.secondary)
                        }

                        if !contextResources.isEmpty {
                            Divider()
                            ForEach(contextResources) { contextResource in
                                OfficialTransitResourceButton(resource: contextResource)
                            }
                            Text(AppLocalization.text(
                                english: "Official context, not a dedicated station page.",
                                simplified: "官方背景资料，非本站专属页面。",
                                traditional: "官方背景資料，非本站專屬頁面。"
                            ))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                    } else {
                        Text(AppLocalization.text(
                            english: "No reviewed official station-information record is available.",
                            simplified: "暂无已审核的官方车站信息记录。",
                            traditional: "暫無已審核的官方車站資訊記錄。"
                        ))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var nativeOfficialStationInformationContent: some View {
        if viewModel == nil ||
            (viewModel?.isLoadingOfficialStationInformation == true &&
                viewModel?.officialStationInformation == nil) ||
            (displayedStation.cityID == "8100" &&
                viewModel?.officialStationInformation == nil &&
                viewModel?.isLoading == true) {
            HStack(spacing: 10) {
                ProgressView()
                Text(AppLocalization.text(
                    english: "Loading official station information",
                    simplified: "正在加载官方车站信息",
                    traditional: "正在載入官方車站資訊"
                ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
        } else if let snapshot = viewModel?.officialStationInformation {
            switch effectiveOfficialInformationCategory {
            case .firstLast:
                officialLineRows(snapshot.lines)
            case .exits:
                officialExitRows(snapshot.exits)
            case .facilities:
                officialFacilityRows(snapshot.facilityGroups)
            }
        } else if let error = viewModel?.officialStationInformationError {
            VStack(alignment: .leading, spacing: 10) {
                Label(error, systemImage: "wifi.exclamationmark")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button {
                    viewModel?.retryRiderInformation()
                } label: {
                    Label(
                        AppLocalization.text(
                            english: "Retry",
                            simplified: "重试",
                            traditional: "重試"
                        ),
                        systemImage: "arrow.clockwise"
                    )
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            officialCategoryEmptyState
        }
    }

    @ViewBuilder
    private func officialLineRows(_ lines: [OfficialStationLineInformation]) -> some View {
        if displayedStation.cityID == "8100",
           viewModel?.isLoading == true,
           lines.isEmpty {
            HStack(spacing: 10) {
                ProgressView()
                Text(AppLocalization.text(
                    english: "Loading live trains",
                    simplified: "正在加载实时列车",
                    traditional: "正在載入即時列車"
                ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
        } else if lines.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                officialCategoryEmptyState
                if displayedStation.cityID == "8100",
                   let message = viewModel?.errorMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        viewModel?.retryRiderInformation()
                    } label: {
                        Label(
                            AppLocalization.text(
                                english: "Retry",
                                simplified: "重试",
                                traditional: "重試"
                            ),
                            systemImage: "arrow.clockwise"
                        )
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                }
            }
        } else {
            // One block per line holding every direction it serves, rather than a flat list that
            // repeated the line name and its colour on each direction.
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                    if index > 0 {
                        Divider()
                    }
                    HStack(alignment: .top, spacing: 10) {
                        Circle()
                            .fill(line.lineColorHex.map(Color.init(hex:)) ?? Color.accentColor)
                            .frame(width: 10, height: 10)
                            .padding(.top, 5)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(line.lineName)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                            ForEach(line.services) { service in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(AppLocalization.text(
                                        english: "Toward \(service.direction)",
                                        simplified: "开往 \(service.direction)",
                                        traditional: "開往 \(service.direction)"
                                    ))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                    if let liveTime = service.liveTime {
                                        Label(liveTime, systemImage: "wave.3.right")
                                            .font(.subheadline)
                                            .fontWeight(.medium)
                                            .foregroundStyle(Color.accentColor)
                                    } else {
                                        HStack(spacing: 16) {
                                            if let firstTrain = service.firstTrain {
                                                trainTimeValue(
                                                    label: AppLocalization.localized("First"),
                                                    value: firstTrain
                                                )
                                            }
                                            if let lastTrain = service.lastTrain {
                                                trainTimeValue(
                                                    label: AppLocalization.localized("Last"),
                                                    value: lastTrain
                                                )
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 10)
                }
            }
        }
    }

    private func trainTimeValue(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline)
                .fontWeight(.semibold)
                .monospacedDigit()
        }
    }

    /// Exits keyed by the street each one opens onto. Operators publish exits as a number plus
    /// the roads it reaches ("1 — 西藏南路 复兴东路") and nothing positional, so this inverts that
    /// same text into "which exit do I take for this street" without inventing any geometry. An
    /// exit reaching two streets is listed under both, which is what its own record says.
    private func officialExitsByStreet(
        _ exits: [OfficialStationExitInformation]
    ) -> [OfficialStationExitStreet] {
        // Beijing and Shanghai list the roads an exit reaches, one per element. Hong Kong's
        // details are descriptive phrases ("Lift access"), which are not places to group by, so
        // it keeps the plain list.
        guard viewModel?.officialStationInformation?.source != .hongKongGovernment else { return [] }
        var order: [String] = []
        var grouped: [String: [OfficialStationExitInformation]] = [:]
        for exit in exits {
            for street in exit.details where !street.isEmpty {
                if grouped[street] == nil {
                    order.append(street)
                }
                grouped[street, default: []].append(exit)
            }
        }
        return order.compactMap { street in
            guard let members = grouped[street] else { return nil }
            return OfficialStationExitStreet(name: street, exits: members)
        }
    }

    @ViewBuilder
    private func officialExitRows(_ exits: [OfficialStationExitInformation]) -> some View {
        if exits.isEmpty {
            officialCategoryEmptyState
        } else {
            let streets = officialExitsByStreet(exits)
            VStack(alignment: .leading, spacing: 0) {
                if streets.isEmpty {
                    // No street text published — fall back to the plain numbered list.
                    officialExitList(exits)
                } else {
                    ForEach(Array(streets.enumerated()), id: \.element.id) { index, street in
                        if index > 0 {
                            Divider()
                        }
                        VStack(alignment: .leading, spacing: 7) {
                            Label(street.name, systemImage: "signpost.right")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: 62), spacing: 6)],
                                alignment: .leading,
                                spacing: 6
                            ) {
                                ForEach(street.exits) { exit in
                                    officialExitChip(exit)
                                }
                            }
                        }
                        .padding(.vertical, 9)
                    }

                    if exits.contains(where: { $0.isAccessible == true }) {
                        Text(AppLocalization.text(
                            english: "Step-free exits are marked.",
                            simplified: "已标记无障碍出入口。",
                            traditional: "已標記無障礙出入口。"
                        ))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                    }
                }
            }
        }
    }

    /// Entrances the bundled pack gives a real position for. Only Taipei publishes these today;
    /// Beijing, Shanghai, Guangzhou and Hong Kong give street text and nothing positional, so
    /// there is nothing to place and the street grouping is the only honest form for them.
    private var mappableAccessPoints: [StationAccessPoint] {
        (viewModel?.accessPoints ?? []).filter { $0.coordinate != nil }
    }

    private var stationCoordinate: CodableCoordinate {
        CodableCoordinate(latitude: displayedStation.latitude, longitude: displayedStation.longitude)
    }

    /// Just the part of an entrance name that tells exits apart. Packs name them in full
    /// ("民權西路站出口1"), which at pin size is a row of identical overlapping labels — on the map
    /// the station is already the centre pin, so only the number carries information. The full
    /// name stays in the accessibility label and in the list below.
    private func shortAccessPointLabel(_ point: StationAccessPoint) -> String {
        var label = point.name
        for stationName in [displayedStation.name, displayedStation.nameEn].compactMap({ $0 }) {
            label = label.replacingOccurrences(of: stationName, with: "")
        }
        for marker in ["站出入口", "站出口", "出入口", "出口", "Exit", "exit", "站"] {
            label = label.replacingOccurrences(of: marker, with: "")
        }
        label = label.trimmingCharacters(in: CharacterSet(charactersIn: " 　-–—:：#号號"))
        return label.isEmpty ? point.name : label
    }

    /// The station and its entrances at their published coordinates. Read-only: it orients the
    /// rider, and the full-screen map is a tab away.
    private func stationAccessPointMap(_ points: [StationAccessPoint]) -> some View {
        let station = displayedStation
        let center = CLLocationCoordinate2D(
            latitude: station.latitude,
            longitude: station.longitude
        )
        return Map(
            initialPosition: .region(
                MKCoordinateRegion(
                    center: center,
                    latitudinalMeters: 420,
                    longitudinalMeters: 420
                )
            ),
            interactionModes: []
        ) {
            Annotation(station.localizedName, coordinate: center) {
                Image(systemName: "tram.fill")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(6)
                    .background(Color.accentColor, in: Circle())
            }
            .annotationTitles(.hidden)

            ForEach(points) { point in
                if let coordinate = point.coordinate {
                    Annotation(
                        point.displayName(relativeTo: stationCoordinate),
                        coordinate: CLLocationCoordinate2D(
                            latitude: coordinate.latitude,
                            longitude: coordinate.longitude
                        )
                    ) {
                        accessPointMarker(point)
                    }
                    .annotationTitles(.hidden)
                }
            }
        }
        .frame(height: stationGuideMapHeight)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityLabel(AppLocalization.text(
            english: "Map of station entrances",
            simplified: "车站出入口地图",
            traditional: "車站出入口地圖"
        ))
    }

    /// A named entrance wears its letter; one OpenStreetMap surveyed without a name is a plain dot,
    /// because four doors on the west side would otherwise all read "West" and tell a rider
    /// nothing. Where the door is on the map is the whole point for those, and the direction is
    /// still spoken to VoiceOver and printed in the list summary below.
    @ViewBuilder
    private func accessPointMarker(_ point: StationAccessPoint) -> some View {
        let spokenName = point.displayName(relativeTo: stationCoordinate)
        let label = point.isAccessible
            ? AppLocalization.text(
                english: "\(spokenName), step-free",
                simplified: "\(spokenName)，无障碍",
                traditional: "\(spokenName)，無障礙"
            )
            : spokenName

        if point.isUnlabeled {
            Circle()
                .fill(point.isAccessible ? Color.green : Color.white)
                .stroke(Color.black.opacity(0.25), lineWidth: 0.5)
                .frame(width: 11, height: 11)
                .accessibilityLabel(label)
        } else {
            Text(shortAccessPointLabel(point))
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundStyle(Color.legibleText(
                    onHex: point.isAccessible ? "#34C759" : "#FFFFFF"
                ))
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .background(
                    point.isAccessible ? Color.green : Color.white,
                    in: Capsule()
                )
                .accessibilityLabel(label)
        }
    }

    /// Drag to resize the map. The handle sits below the map rather than on it so the gesture never
    /// competes with the enclosing ScrollView, and VoiceOver gets an adjustable action because
    /// there is no way to drag a handle by voice.
    private func clampedMapHeight(_ value: Double) -> Double {
        min(
            max(value, StationDetailView.mapHeightRange.lowerBound),
            StationDetailView.mapHeightRange.upperBound
        )
    }

    private var mapResizeHandle: some View {
        let step: Double = 60
        return Capsule()
            .fill(Color.secondary.opacity(0.4))
            .frame(width: 44, height: 5)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        let base = mapHeightAtDragStart ?? stationGuideMapHeight
                        mapHeightAtDragStart = base
                        stationGuideMapHeight = clampedMapHeight(base + value.translation.height)
                    }
                    .onEnded { _ in mapHeightAtDragStart = nil }
            )
            .accessibilityElement()
            .accessibilityLabel(AppLocalization.text(
                english: "Map height",
                simplified: "地图高度",
                traditional: "地圖高度"
            ))
            .accessibilityValue(AppLocalization.text(
                english: "\(Int(stationGuideMapHeight)) points",
                simplified: "\(Int(stationGuideMapHeight)) 点",
                traditional: "\(Int(stationGuideMapHeight)) 點"
            ))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    stationGuideMapHeight = clampedMapHeight(stationGuideMapHeight + step)
                case .decrement:
                    stationGuideMapHeight = clampedMapHeight(stationGuideMapHeight - step)
                @unknown default:
                    break
                }
            }
    }

    private func officialExitChip(_ exit: OfficialStationExitInformation) -> some View {
        let isAccessible = exit.isAccessible == true
        return HStack(spacing: 4) {
            if isAccessible {
                Image(systemName: "figure.roll")
                    .font(.caption2)
            }
            Text(exit.name)
                .font(.caption)
                .fontWeight(.medium)
        }
        .foregroundStyle(isAccessible ? Color.green : Color.accentColor)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            (isAccessible ? Color.green : Color.accentColor).opacity(0.14),
            in: Capsule()
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isAccessible
            ? AppLocalization.text(
                english: "Exit \(exit.name), step-free",
                simplified: "出入口 \(exit.name)，无障碍",
                traditional: "出入口 \(exit.name)，無障礙"
            )
            : AppLocalization.text(
                english: "Exit \(exit.name)",
                simplified: "出入口 \(exit.name)",
                traditional: "出入口 \(exit.name)"
            )
        )
    }

    private func officialExitList(_ exits: [OfficialStationExitInformation]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(exits.enumerated()), id: \.element.id) { index, exit in
                if index > 0 {
                    Divider()
                }
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: exit.isAccessible == true
                        ? "figure.roll"
                        : "door.left.hand.open")
                        .foregroundStyle(exit.isAccessible == true ? .green : Color.accentColor)
                        .frame(width: 22)
                    Text(exit.name)
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 9)
            }
        }
    }

    @ViewBuilder
    private func officialFacilityRows(
        _ groups: [OfficialStationFacilityGroup]
    ) -> some View {
        if groups.isEmpty {
            officialCategoryEmptyState
        } else {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(group.name)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        ForEach(group.items) { item in
                            let isUnavailable = item.availability == .unavailable
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: isUnavailable
                                    ? "xmark.circle.fill"
                                    : "checkmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(isUnavailable ? .red : .green)
                                    .padding(.top, 2)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name)
                                        .font(.subheadline)
                                    if let location = item.location {
                                        Text(location)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    } else if isUnavailable {
                                        Text(AppLocalization.localized("Not available"))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 6)
        }
    }

    private var officialCategoryEmptyState: some View {
        let category = effectiveOfficialInformationCategory
        let categoryTitle = category.title(for: displayedStation.cityID)
        return Label {
            Text(AppLocalization.text(
                english: "No \(categoryTitle.lowercased()) for this station.",
                simplified: "暂无本站\(categoryTitle)。",
                traditional: "暫無本站\(categoryTitle)。"
            ))
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: category.icon)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }

    private var officialStationInformationProvenance: String {
        if displayedStation.cityID == "8100" {
            return AppLocalization.text(
                english: "Live trains online · accessibility data included offline",
                simplified: "列车信息在线获取 · 无障碍数据已离线内置",
                traditional: "列車資訊線上取得 · 無障礙資料已離線內置"
            )
        }
        if case .cached(let fetchedAt) = viewModel?.officialStationInformation?.freshness {
            let age = fetchedAt.formatted(.relative(presentation: .named))
            return AppLocalization.text(
                english: "Cached · \(age)",
                simplified: "已缓存 · \(age)",
                traditional: "已快取 · \(age)"
            )
        }
        return AppLocalization.text(
            english: "Live · saved offline",
            simplified: "实时 · 已离线保存",
            traditional: "即時 · 已離線保存"
        )
    }

    private func officialStationInformationConfidence(
        _ status: OfficialTransitStationInformationStatus?,
        cityID: String
    ) -> DataConfidence {
        if cityID == "8100" {
            return viewModel == nil || viewModel?.isLoadingCityPack == true
                ? .unknown
                : .official
        }
        switch status {
        case .exactPage, .officialContextOnly:
            return .official
        case .notOpenForPassengerService, .noCurrentPassengerService:
            return .unavailable
        case nil:
            // A loaded live snapshot is itself official data. The reviewed-resource record only
            // covers the operator's *page*, and Shanghai/Guangzhou stations carry no review row,
            // so without this the chip read "No data" directly above verified first/last times.
            return viewModel?.officialStationInformation == nil ? .unknown : .official
        }
    }

    private func officialStationInformationStatusText(
        _ status: OfficialTransitStationInformationStatus?
    ) -> String {
        switch status {
        case .exactPage:
            return AppLocalization.text(
                english: "Exact official station page available.",
                simplified: "已有本站的精确官方页面。",
                traditional: "已有本站的精確官方頁面。"
            )
        case .officialContextOnly:
            return AppLocalization.text(
                english: "Official line/operator context only — no dedicated station page.",
                simplified: "仅有官方线路或运营背景资料，没有本站专属页面。",
                traditional: "僅有官方路線或營運背景資料，沒有本站專屬頁面。"
            )
        case .notOpenForPassengerService:
            return AppLocalization.text(
                english: "Not yet open for passenger service.",
                simplified: "尚未开放客运服务。",
                traditional: "尚未開放客運服務。"
            )
        case .noCurrentPassengerService:
            return AppLocalization.text(
                english: "Not a current passenger stop.",
                simplified: "非当前客运停靠站。",
                traditional: "非目前客運停靠站。"
            )
        case nil:
            return AppLocalization.text(
                english: "No official station page available.",
                simplified: "暂无官方车站页面。",
                traditional: "暫無官方車站頁面。"
            )
        }
    }

    /// "Station Guide" — the specific entrance/exit guidance riders ask for, plus any authored
    /// platform hints, labeled with a confidence chip. Sits above Train Times.

    /// Whether the official online section above is already rendering this station's exit list.
    private var officialSurfaceListsExits: Bool {
        usesNativeStationInformationSurface &&
            viewModel?.officialStationInformation?.exits.isEmpty == false
    }

    @ViewBuilder
    var stationGuideSection: some View {
        let exits = viewModel?.accessPoints ?? []
        let platformHints = viewModel?.platformHints ?? []
        if viewModel?.isLoadingCityPack == true || !exits.isEmpty || !platformHints.isEmpty {
            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(AppLocalization.text(english: "Station Guide", simplified: "进出站指引", traditional: "進出站指引"))
                            .font(.headline)
                        Spacer()
                        DataConfidenceChip(confidence: viewModel?.guideConfidence ?? .unknown, compact: true)
                    }

                    if viewModel?.isLoadingCityPack == true {
                        ProgressView()
                    } else if !exits.isEmpty {
                        Text(AppLocalization.text(english: "Exits & entrances", simplified: "出入口", traditional: "出入口"))
                            .font(.subheadline)
                            .fontWeight(.medium)

                        // Drawn only where the pack publishes real entrance coordinates, so the
                        // pins are surveyed positions rather than a guess.
                        let mappable = mappableAccessPoints
                        if !mappable.isEmpty {
                            stationAccessPointMap(mappable)
                            mapResizeHandle
                        }

                        // The official online surface lists this station's *named* exits already,
                        // with the streets each one reaches — richer than a bare name. Repeating
                        // those would print the same list twice on one screen. It never covers the
                        // unlabeled entrances, so those stay either way.
                        let listed = officialSurfaceListsExits ? exits.filter(\.isUnlabeled) : exits
                        ForEach(listed.presentationGroups(relativeTo: stationCoordinate)) { group in
                            StationAccessPointRow(group: group)
                        }
                    }

                    if !platformHints.isEmpty {
                        if !exits.isEmpty {
                            Divider()
                        }
                        Text(AppLocalization.text(english: "On the platform", simplified: "站台提示", traditional: "月台提示"))
                            .font(.subheadline)
                            .fontWeight(.medium)
                        ForEach(Array(platformHints.enumerated()), id: \.offset) { _, hint in
                            PlatformHintRow(hint: hint)
                        }
                    }

                }
            }
        }
    }

    var arrivalsSection: some View {
        let arrivals = viewModel?.arrivals ?? []
        return GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(AppLocalization.localized("Train Times"))
                    .font(.headline)

                if viewModel?.isLoading == true {
                    ProgressView()
                } else if arrivals.isEmpty {
                    Text(viewModel?.errorMessage ?? AppLocalization.localized("Schedule unavailable"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(arrivals) { arrival in
                        ArrivalCountdown(arrival: arrival)
                    }

                    if let statusMessage = viewModel?.trainTimeStatusMessage {
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    var stationEssentialsSection: some View {
        let station = displayedStation
        let facilities = station.facilities.deduplicatedForDisplay()
        if !facilities.isEmpty {
            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text(AppLocalization.localized("Station Essentials"))
                        .font(.headline)

                    ForEach(facilities) { facility in
                        facilityRow(facility)
                    }
                }
            }
        }
    }

    private func facilityRow(_ facility: StationFacility) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: facility.type.iconName)
                .foregroundStyle(facility.type.isAccessibilityCritical ? .green : .blue)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(facility.name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                if let location = facility.locationText, !location.isEmpty {
                    Text(location)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("\(facility.source.label) • \(facility.verification.label)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

    @ViewBuilder
    var stationMapSection: some View {
        let resources = (viewModel?.externalResources ?? []).filter {
            $0.kind != .stationInformation
        }
        let media = viewModel?.licensedMedia ?? []
        if viewModel?.isLoadingCityPack == true || !resources.isEmpty || !media.isEmpty || viewModel?.stationLayoutStatusMessage != nil {
            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text(AppLocalization.text(
                        english: "Station Resources",
                        simplified: "车站资源",
                        traditional: "車站資源"
                    ))
                        .font(.headline)

                    if viewModel?.isLoadingCityPack == true {
                        ProgressView()
                    } else {
                        ForEach(resources) { resource in
                            OfficialTransitResourceButton(resource: resource, compact: true)
                        }

                        ForEach(media) { item in
                            licensedMediaContent(item)
                        }
                    }

                    if let statusMessage = viewModel?.stationLayoutStatusMessage {
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func licensedMediaContent(_ media: LicensedStationMedia) -> some View {
        if let url = media.bundledURL {
            VStack(alignment: .leading, spacing: 6) {
                Text(media.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                localStationImage(
                    url: url,
                    title: media.title
                )
                Text("\(media.attribution) · \(media.licenseSPDX)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(media.modifications)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 16) {
                    if let sourceURL = URL(string: media.sourcePageURL) {
                        Link(destination: sourceURL) {
                            Label(
                                AppLocalization.text(
                                    english: "Source page",
                                    simplified: "来源页面",
                                    traditional: "來源頁面"
                                ),
                                systemImage: "arrow.up.right.square"
                            )
                        }
                    }
                    if let licenseURL = URL(string: media.licenseURL) {
                        Link(destination: licenseURL) {
                            Label(media.licenseSPDX, systemImage: "doc.text")
                        }
                    }
                }
                .font(.caption)
            }
        }
    }

    @ViewBuilder
    private func localStationImage(url: URL, title: String) -> some View {
        StationAssetImage(url: url) { image in
            Button {
                selectedStationImage = FullScreenStationImage(url: url, title: title)
            } label: {
                image
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 160)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 1)
                    }
                }
            .buttonStyle(.plain)
            .accessibilityLabel(AppLocalization.localized("Open station image full screen"))
        } failure: {
            Text(AppLocalization.text(
                english: "Station media could not be loaded",
                simplified: "车站媒体无法加载",
                traditional: "車站媒體無法載入"
            ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

}

private extension Array where Element == StationFacility {
    func deduplicatedForDisplay() -> [StationFacility] {
        uniqued { facility in
            [
                facility.type.rawValue,
                facility.name.normalizedFacilityText,
                (facility.locationText ?? "").normalizedFacilityText,
                facility.source.rawValue,
                facility.verification.rawValue
            ].joined(separator: "|")
        }
    }
}

private extension String {
    var normalizedFacilityText: String {
        String(filter { !$0.isWhitespace })
            .replacingOccurrences(of: "，", with: ",")
            .replacingOccurrences(of: "。", with: ".")
            .replacingOccurrences(of: "（", with: "(")
            .replacingOccurrences(of: "）", with: ")")
            .lowercased()
    }
}
