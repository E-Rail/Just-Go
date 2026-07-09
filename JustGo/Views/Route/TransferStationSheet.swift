import SwiftUI
import CoreLocation
import MapKit

struct TransferStationSheet: View {
    let transferSegment: RouteSegment
    let nextTransitSegment: RouteSegment?
    let cityID: String
    let crowdControl: RouteCrowdControl
    let accessibilityFilter: AccessibilityFilter

    @Environment(DIContainer.self) private var container
    @State private var enrichedStation: Station?
    @State private var isLoadingStation = false
    @State private var lookAroundScene: MKLookAroundScene?
    @State private var guidance: StationAccessGuidance?
    @State private var stationMap: CityPackStationMap?
    @State private var indoorMap: StationIndoorMap?
    @State private var transferPath: TransferPathHint?
    @State private var doorGuidance: DoorGuidance?
    @State private var fullScreenImage: FullScreenStationImage?

    private var stationName: String {
        transferSegment.fromStationName ?? AppLocalization.localized("Transfer station")
    }

    private var crowdWindows: [String] {
        crowdControl.stations.first { $0.stationName == stationName }?.windows ?? []
    }

    /// The transfer station's real coordinate. A transfer segment's own stationStops is always
    /// empty by construction — the coordinate lives on the ride segment that follows it (same
    /// station, matched by ID with a defensive first-stop fallback).
    private var transferStopCoordinate: CLLocationCoordinate2D? {
        let stop = nextTransitSegment?.stationStops.first { $0.stationID == transferSegment.toStationID }
            ?? nextTransitSegment?.stationStops.first
        return stop?.coordinate.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerSection
                rideSection
                stationMapSection
                transferGuideSection
                accessibilitySection
                if !crowdWindows.isEmpty {
                    crowdControlSection
                }
                lookAroundSection
            }
            .padding()
        }
        .background(Color.appBackground)
        .navigationTitle(stationName)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $fullScreenImage) { image in
            FullScreenStationImageView(image: image)
        }
        .task {
            isLoadingStation = true
            defer { isLoadingStation = false }
            // Match only when the route carries the real transfer-station coordinate
            // (provider-built routes always do). With a (0,0) placeholder, same-named
            // stations disambiguate by distance to Null Island and pick an arbitrary one —
            // showing the wrong station's accessibility data is worse than showing none.
            if let coordinate = transferStopCoordinate {
                let place = TransitPlace(
                    name: stationName,
                    coordinate: coordinate,
                    source: .localStationData
                )
                enrichedStation = await container.officialStationData.matchingStation(place: place, cityID: cityID)
            }
            if !cityID.isEmpty {
                // Exits/corridor/platform guidance and the official station map are keyed by
                // station NAME in the pack, so they still resolve when matchingStation found
                // no full record (a minimal name+coordinate station suffices for the lookup).
                guidance = (await container.officialStationData.stationGuidance(
                    cityID: cityID,
                    stationNames: [stationName]
                ))[stationName]
                let mapLookupStation = enrichedStation ?? Station(
                    stationID: transferSegment.toStationID ?? stationName,
                    name: stationName,
                    nameEn: nil,
                    latitude: transferStopCoordinate?.latitude ?? 0,
                    longitude: transferStopCoordinate?.longitude ?? 0,
                    cityID: cityID
                )
                stationMap = await container.officialStationData.stationMap(for: mapLookupStation)
                indoorMap = await container.officialStationData.indoorMap(for: mapLookupStation)
                transferPath = await container.officialStationData.transferPath(
                    for: mapLookupStation,
                    fromLineName: transferSegment.lineName,
                    toLineName: nextTransitSegment?.lineName,
                    accessibilityFilter: accessibilityFilter
                )
                doorGuidance = await container.officialStationData.doorGuidance(
                    for: mapLookupStation,
                    lineName: nextTransitSegment?.lineName,
                    directionText: nextTransitSegment?.toStationName,
                    target: .transfer
                )
            }
            // Street view keys off the route's own coordinate first so it still works when the
            // official pack doesn't list this station (matchingStation returned nil above).
            if let coordinate = transferStopCoordinate ?? enrichedStation?.coordinate,
               CLLocationCoordinate2DIsValid(coordinate),
               coordinate.latitude != 0 || coordinate.longitude != 0 {
                lookAroundScene = try? await MKLookAroundSceneRequest(coordinate: coordinate).scene
            }
        }
    }

    private var headerSection: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.title2)
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(stationName)
                    .font(.title3)
                    .fontWeight(.semibold)

                if let nextLine = nextTransitSegment?.lineName {
                    let colorHex = nextTransitSegment?.lineColorHex ?? "#888888"
                    Label(nextLine, systemImage: "tram.fill")
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color(hex: colorHex), in: Capsule())
                }
            }
        }
    }

    /// Transfer time and onward direction in ONE compact card — each used to be its own
    /// card holding a single line. The direction is the line a rider actually needs on the
    /// platform, so it gets the visual weight.
    private var rideSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                if let nextSegment = nextTransitSegment,
                   let lineName = nextSegment.lineName, let toward = nextSegment.toStationName {
                    Text(AppLocalization.text(
                        english: "Board \(lineName) toward \(toward)",
                        simplified: "乘\(lineName)方向 \(toward)",
                        traditional: "乘\(lineName)方向 \(toward)"
                    ))
                    .font(.subheadline)
                    .fontWeight(.semibold)
                }
                Label {
                    Text(AppLocalization.text(
                        english: "Transfer walk about \(transferSegment.formattedDuration)",
                        simplified: "换乘步行约\(transferSegment.formattedDuration)",
                        traditional: "換乘步行約\(transferSegment.formattedDuration)"
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "figure.walk")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// The in-station walkthrough riders (especially less sign-savvy ones) ask for: which
    /// exits/entrances exist, the transfer corridor, and boarding car/door hints — each
    /// shown when the pack has it, and honestly marked pending when it doesn't.
    private var transferGuideSection: some View {
        let exits = guidance?.accessPoints ?? []
        let corridorHints = guidance?.interchangeHints ?? []
        let platformHints = guidance?.platformHints ?? []
        return GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(AppLocalization.text(english: "Transfer Guide", simplified: "换乘指引", traditional: "換乘指引"))
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Spacer()
                    DataConfidenceChip(confidence: guidance?.confidence ?? .unknown, compact: true)
                }

                if isLoadingStation {
                    ProgressView()
                } else {
                    if exits.isEmpty {
                        Text(AppLocalization.text(
                            english: "Specific exit data is not available yet — see the station map below.",
                            simplified: "暂无具体出入口数据，请参考下方站内图。",
                            traditional: "暫無具體出入口資料，請參考下方站內圖。"
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    } else {
                        Text(AppLocalization.text(english: "Exits & entrances", simplified: "出入口", traditional: "出入口"))
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                        ForEach(exits) { exit in
                            HStack(spacing: 8) {
                                Image(systemName: exit.isAccessible ? "figure.roll" : "figure.walk")
                                    .foregroundStyle(exit.isAccessible ? .green : Color.accentColor)
                                    .frame(width: 22)
                                Text(exit.name)
                                    .font(.subheadline)
                                if exit.isAccessible {
                                    Text(AppLocalization.text(english: "Step-free", simplified: "无障碍", traditional: "無障礙"))
                                        .font(.caption2)
                                        .foregroundStyle(.green)
                                }
                                Spacer()
                            }
                        }
                    }

                    if !corridorHints.isEmpty {
                        Divider()
                        ForEach(Array(corridorHints.enumerated()), id: \.offset) { _, hint in
                            corridorHintRow(hint)
                        }
                    }

                    if !platformHints.isEmpty {
                        Divider()
                        ForEach(Array(platformHints.enumerated()), id: \.offset) { _, hint in
                            platformHintRow(hint)
                        }
                    }

                    Divider()
                    indoorGuidanceStatus
                }
            }
        }
    }

    @ViewBuilder
    private var indoorGuidanceStatus: some View {
        if let transferPath {
            corridorPathRow(transferPath)
        } else if let doorGuidance {
            doorGuidanceRow(doorGuidance)
        } else {
            Label {
                Text(AppLocalization.text(
                    english: "Verified 3D indoor path, car, and door guidance is not collected for this station yet.",
                    simplified: "本站尚未收录经验证的 3D 站内路径、车厢和车门指引。",
                    traditional: "本站尚未收錄經驗證的 3D 站內路徑、車廂和車門指引。"
                ))
                .font(.caption2)
                .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "cube.transparent")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func corridorPathRow(_ path: TransferPathHint) -> some View {
        var parts: [String] = []
        if let meters = path.walkingMeters {
            parts.append(AppLocalization.text(
                english: "about \(Int(meters)) m",
                simplified: "约\(Int(meters))米",
                traditional: "約\(Int(meters))米"
            ))
        }
        if let minutes = path.walkingMinutes {
            parts.append(AppLocalization.minutes(Int(minutes.rounded())))
        }
        return Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(parts.isEmpty ? AppLocalization.text(english: "Verified indoor transfer path", simplified: "经验证的站内换乘路径", traditional: "經驗證的站內轉乘路徑") : parts.joined(separator: " · "))
                    .font(.caption)
                if path.routeNodeIDs.count > 1 {
                    Text(AppLocalization.text(
                        english: "Path highlighted on the station map above.",
                        simplified: "路径已在上方站内图中标出。",
                        traditional: "路徑已在上方站內圖中標出。"
                    ))
                    .font(.caption2)
                    .foregroundStyle(Color.accentColor)
                }
                ForEach(path.notes, id: \.self) { note in
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                .font(.caption)
                .foregroundStyle(Color.accentColor)
        }
    }

    private func doorGuidanceRow(_ guidance: DoorGuidance) -> some View {
        let cars = guidance.recommendedCars
            .map { AppLocalization.text(english: "Car \($0)", simplified: "\($0)车", traditional: "\($0)車") }
            .joined(separator: " · ")
        let parts = [
            cars.isEmpty ? nil : cars,
            guidance.recommendedDoorText?.nilIfEmpty
        ].compactMap { $0 }
        return Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(parts.isEmpty
                    ? AppLocalization.text(english: "Verified door guidance", simplified: "经验证的车门指引", traditional: "經驗證的車門指引")
                    : parts.joined(separator: " · ")
                )
                    .font(.caption)
                ForEach(guidance.notes, id: \.self) { note in
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: "tram.fill")
                .font(.caption)
                .foregroundStyle(Color.accentColor)
        }
    }

    /// Corridor hint between the two lines: "2号线 → 8号线 · 约180米 · 3分钟" plus notes.
    private func corridorHintRow(_ hint: StationInterchangeHint) -> some View {
        var parts: [String] = []
        if let from = hint.fromLineName, let to = hint.toLineName {
            parts.append("\(from) → \(to)")
        }
        if let meters = hint.walkingMeters {
            parts.append(AppLocalization.text(
                english: "about \(Int(meters)) m",
                simplified: "约\(Int(meters))米",
                traditional: "約\(Int(meters))米"
            ))
        }
        if let minutes = hint.walkingMinutes {
            parts.append(AppLocalization.minutes(Int(minutes.rounded())))
        }
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: "arrow.triangle.turn.up.right.diamond")
                .font(.caption)
                .foregroundStyle(Color.accentColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                if !parts.isEmpty {
                    Text(parts.joined(separator: " · "))
                        .font(.subheadline)
                }
                ForEach(hint.notes, id: \.self) { note in
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    private func platformHintRow(_ hint: StationPlatformHint) -> some View {
        let parts = [hint.lineName, hint.directionText, hint.boardingCarText, hint.doorSideText]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: "tram.fill")
                .font(.caption)
                .foregroundStyle(Color.accentColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                if !parts.isEmpty {
                    Text(parts.joined(separator: " · "))
                        .font(.subheadline)
                }
                ForEach(hint.notes, id: \.self) { note in
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    /// Official in-station map when the pack collected one; tap for full screen.
    @ViewBuilder
    private var stationMapSection: some View {
        if let stationMap, stationMap.isImage, let url = stationMap.resolvedURL {
            GlassCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text(AppLocalization.localized("Station Map"))
                        .font(.subheadline)
                        .fontWeight(.medium)
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            Button {
                                fullScreenImage = FullScreenStationImage(
                                    url: url,
                                    title: stationMap.title ?? AppLocalization.localized("Station Map")
                                )
                            } label: {
                                image
                                    .resizable()
                                    .scaledToFit()
                                    .overlay(indoorPathOverlay)
                                    .frame(maxWidth: .infinity)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                        case .failure:
                            Text(AppLocalization.localized("Station map could not be loaded"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        default:
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 24)
                        }
                    }
                    Text(AppLocalization.text(
                        english: "Tap to zoom — official station layout.",
                        simplified: "点按放大查看官方站内图。",
                        traditional: "點按放大查看官方站內圖。"
                    ))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
        } else if indoorMap == nil {
            GlassCard {
                Label {
                    Text(AppLocalization.text(
                        english: "Official station map is not collected yet.",
                        simplified: "官方站内图尚未收录。",
                        traditional: "官方站內圖尚未收錄。"
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "map")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Draws `transferPath`'s route directly on the station image above. Chained right after
    /// `.scaledToFit()` (before the outer `.frame`/`.clipShape`), so this overlay's own layout
    /// size exactly matches the image's letterboxed content rect — no manual aspect-ratio math
    /// needed. Node coordinates are fractional (0...1) of that same rect (see `IndoorCoordinate`).
    @ViewBuilder
    private var indoorPathOverlay: some View {
        if let indoorMap, let transferPath, transferPath.routeNodeIDs.count > 1 {
            let nodesByID = Dictionary(uniqueKeysWithValues: indoorMap.nodes.map { ($0.id, $0) })
            let points = transferPath.routeNodeIDs.compactMap { nodesByID[$0]?.coordinate }
            Canvas { context, size in
                guard points.count > 1 else { return }
                let resolved = points.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }

                var path = Path()
                path.addLines(resolved)
                context.stroke(
                    path,
                    with: .color(.accentColor),
                    style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round)
                )

                if let start = resolved.first {
                    let dot = CGRect(x: start.x - 6, y: start.y - 6, width: 12, height: 12)
                    context.fill(Path(ellipseIn: dot), with: .color(.accentColor))
                    context.stroke(Path(ellipseIn: dot), with: .color(.white), lineWidth: 2)
                }
                if let end = resolved.last {
                    let marker = CGRect(x: end.x - 8, y: end.y - 8, width: 16, height: 16)
                    context.fill(Path(ellipseIn: marker), with: .color(.green))
                    context.stroke(Path(ellipseIn: marker), with: .color(.white), lineWidth: 2)
                }
            }
            .allowsHitTesting(false)
        }
    }

    /// Elevator / ramp / accessible restroom as one compact row of tri-state chips
    /// (✓ / ✗ / ?) — three full-width rows said the same thing in 3× the height.
    @ViewBuilder
    private var accessibilitySection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(AppLocalization.text(english: "Accessibility", simplified: "无障碍", traditional: "無障礙"))
                    .font(.subheadline)
                    .fontWeight(.medium)

                if isLoadingStation {
                    HStack {
                        ProgressView()
                        Text(AppLocalization.text(english: "Loading station info…", simplified: "加载中…", traditional: "載入中…"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let station = enrichedStation {
                    let acc = station.accessibility
                    let accessibleRestroom = station.facilities.first { $0.type == .accessibleRestroom }
                    HStack(spacing: 8) {
                        accessibilityChip(
                            title: AppLocalization.text(english: "Elevator", simplified: "电梯", traditional: "電梯"),
                            icon: "arrow.up.arrow.down.circle.fill",
                            available: acc?.hasElevator
                        )
                        accessibilityChip(
                            title: AppLocalization.text(english: "Ramp", simplified: "坡道", traditional: "坡道"),
                            icon: "figure.roll",
                            available: acc?.hasWheelchairRamp
                        )
                        accessibilityChip(
                            title: AppLocalization.text(english: "Restroom", simplified: "无障碍卫生间", traditional: "無障礙廁所"),
                            icon: "toilet",
                            available: accessibleRestroom != nil ? true : nil
                        )
                    }
                } else {
                    Text(AppLocalization.text(
                        english: "Accessibility data unavailable for this station.",
                        simplified: "此站点无障碍数据不可用。",
                        traditional: "此站點無障礙資料不可用。"
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func accessibilityChip(title: String, icon: String, available: Bool?) -> some View {
        let tint: Color = available == true ? .green : available == false ? .red : .secondary
        return HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.caption)
            Text(title)
                .font(.caption)
                .lineLimit(1)
            Image(systemName: available == true ? "checkmark.circle.fill" : available == false ? "xmark.circle.fill" : "questionmark.circle")
                .font(.caption)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(tint.opacity(0.1), in: Capsule())
        .accessibilityLabel("\(title): \(available == true ? AppLocalization.localized("Available") : available == false ? AppLocalization.text(english: "Not available", simplified: "无", traditional: "無") : AppLocalization.text(english: "Unknown", simplified: "未知", traditional: "未知"))")
    }

    private var crowdControlSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                Label(
                    AppLocalization.text(english: "Crowd Control Windows", simplified: "限流时段", traditional: "限流時段"),
                    systemImage: "person.3.fill"
                )
                .font(.subheadline)
                .fontWeight(.medium)

                ForEach(crowdWindows, id: \.self) { window in
                    Text(window)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Apple's Look Around has no coverage underground, so this can only ever show the
    /// station's street-level entrance, not the platform itself — the caption makes that
    /// explicit. Renders nothing when no coverage exists for the coordinate.
    @ViewBuilder
    private var lookAroundSection: some View {
        if let lookAroundScene {
            VStack(alignment: .leading, spacing: 6) {
                LookAroundPreview(initialScene: lookAroundScene)
                    .frame(height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                Text(AppLocalization.text(
                    english: "Station entrance (street view)",
                    simplified: "车站入口（街景）",
                    traditional: "車站入口（街景）"
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
