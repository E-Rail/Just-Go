import SwiftUI
import CoreLocation
import MapKit

struct TransferStationSheet: View {
    let transferSegment: RouteSegment
    let nextTransitSegment: RouteSegment?
    let cityID: String
    let accessibilityFilter: AccessibilityFilter

    @Environment(DIContainer.self) private var container
    @State private var enrichedStation: Station?
    @State private var isLoadingStation = false
    @State private var lookAroundScene: MKLookAroundScene?
    @State private var guidance: StationAccessGuidance?
    @State private var externalResources: [ExternalTransitResource] = []

    private var stationName: String {
        transferSegment.fromStationName ?? AppLocalization.localized("Transfer station")
    }

    /// The transfer station's coordinate: a transfer segment has no stops, so it comes from the
    /// ride that follows (same station, matched by ID, first stop as fallback).
    private var transferStopCoordinate: CLLocationCoordinate2D? {
        let stop = nextTransitSegment?.stationStops.first { $0.stationID == transferSegment.toStationID }
            ?? nextTransitSegment?.stationStops.first
        return stop?.coordinate.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
    }

    /// What entrances without a sign letter are described relative to; without it they read
    /// "station entrance".
    private var stationCoordinate: CodableCoordinate? {
        (transferStopCoordinate ?? enrichedStation?.coordinate).map(CodableCoordinate.init)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                rideSection
                stationMapSection
                stationExitsSection
                accessibilitySection
                lookAroundSection
            }
            .padding()
        }
        .background(Color.appBackground)
        .navigationTitle(stationName)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            isLoadingStation = true
            defer { isLoadingStation = false }
            let initialLookupStation = Station(
                stationID: transferSegment.toStationID ?? stationName,
                name: stationName,
                nameEn: nil,
                latitude: transferStopCoordinate?.latitude ?? 0,
                longitude: transferStopCoordinate?.longitude ?? 0,
                cityID: cityID
            )
            async let initialResourceLoad = container.officialStationData.externalResources(for: initialLookupStation)
            // Match only with the real coordinate: a (0,0) placeholder picks among same-named
            // stations by distance to Null Island, and the wrong station's accessibility data is
            // worse than none.
            if let coordinate = transferStopCoordinate {
                let place = TransitPlace(
                    name: stationName,
                    coordinate: coordinate,
                    source: .localStationData
                )
                enrichedStation = await container.officialStationData.matchingStation(place: place, cityID: cityID)
            }
            if !cityID.isEmpty {
                // Exits and official pages are keyed by station name in the pack, so they resolve
                // even when `matchingStation` found no full record.
                guidance = (await container.officialStationData.stationGuidance(
                    cityID: cityID,
                    stationNames: [stationName]
                ))[stationName]
                let mapLookupStation = enrichedStation ?? initialLookupStation
                let initialResources = await initialResourceLoad
                if initialResources.isEmpty, enrichedStation != nil {
                    externalResources = await container.officialStationData.externalResources(for: mapLookupStation)
                } else {
                    externalResources = initialResources
                }
            }
            // Street view uses the route's own coordinate first, so it works when the pack does not
            // list this station.
            if let coordinate = transferStopCoordinate ?? enrichedStation?.coordinate,
               CLLocationCoordinate2DIsValid(coordinate),
               coordinate.latitude != 0 || coordinate.longitude != 0 {
                lookAroundScene = try? await MKLookAroundSceneRequest(coordinate: coordinate).scene
            }
        }
    }

    /// The whole instruction, which line, which direction, how long the walk, beside the badge of
    /// the line to look for.
    private var rideSection: some View {
        GlassCard {
            HStack(alignment: .top, spacing: 12) {
                if let nextSegment = nextTransitSegment, let lineName = nextSegment.lineName {
                    LineBadge(name: lineName, colorHex: nextSegment.lineColorHex, size: 34)
                }
                VStack(alignment: .leading, spacing: 6) {
                    // Toward the terminus the platform sign names, not where this rider alights;
                    // absent where the branch is ambiguous, as on the leg row.
                    if let nextSegment = nextTransitSegment,
                       let lineName = nextSegment.lineName,
                       let toward = nextSegment.transitContext?.directionTerminalStationName {
                        Text(AppLocalization.text(
                            english: "Board \(lineName) toward \(toward)",
                            simplified: "乘\(lineName)方向 \(toward)",
                            traditional: "乘\(lineName)方向 \(toward)"
                        ))
                        .font(.headline)
                    }
                    Label {
                        Text(AppLocalization.text(
                            english: "Transfer walk about \(transferSegment.formattedDuration)",
                            simplified: "换乘步行约\(transferSegment.formattedDuration)",
                            traditional: "換乘步行約\(transferSegment.formattedDuration)"
                        ))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "figure.walk")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    // An out-of-station change and its fare, as the leg row says them.
                    ForEach(transferSegment.accessibilityNotes, id: \.self) { note in
                        Label(note, systemImage: "info.circle")
                            .font(.footnote)
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
        }
    }

    /// The station's exits, where the pack has them.
    @ViewBuilder
    private var stationExitsSection: some View {
        let exits = guidance?.accessPoints ?? []
        if isLoadingStation || !exits.isEmpty {
            GlassCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text(AppLocalization.text(english: "Exits & entrances", simplified: "出入口", traditional: "出入口"))
                        .font(.subheadline)
                        .fontWeight(.medium)
                    if isLoadingStation {
                        ProgressView()
                    } else {
                        ForEach(exits.presentationGroups(relativeTo: stationCoordinate)) { group in
                            StationAccessPointRow(group: group)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var stationMapSection: some View {
        let relevantResources = externalResources.filter(\.kind.isTransferRelevant)
        // Drawn only when there is something to link to.
        if !relevantResources.isEmpty {
            GlassCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text(AppLocalization.text(
                        english: "Official Station Resources",
                        simplified: "官方车站资源",
                        traditional: "官方車站資源"
                    ))
                    .font(.subheadline)
                    .fontWeight(.medium)

                    ForEach(relevantResources) { resource in
                        OfficialTransitResourceButton(resource: resource, compact: true)
                    }
                    Text(AppLocalization.text(
                        english: "Straight from the operator, opened here for you to read.",
                        simplified: "由运营方提供，可在此直接查看。",
                        traditional: "由營運方提供，可在此直接查看。"
                    ))
                        .rowMeta()
                }
            }
        }
    }

    /// Elevator, ramp and accessible restroom as one row of tri-state chips (✓ / ✗ / ?).
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
                            .rowMeta()
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
                    .rowMeta()
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

    /// Look Around has no underground coverage, so this shows the station's street-level entrance,
    /// and the caption says so. Nothing is drawn without coverage.
    @ViewBuilder
    private var lookAroundSection: some View {
        if let lookAroundScene {
            VStack(alignment: .leading, spacing: 6) {
                LookAroundPreview(initialScene: lookAroundScene)
                    .frame(height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
                Text(AppLocalization.text(
                    english: "Station entrance (street view)",
                    simplified: "车站入口（街景）",
                    traditional: "車站入口（街景）"
                ))
                .rowMeta()
            }
        }
    }
}
