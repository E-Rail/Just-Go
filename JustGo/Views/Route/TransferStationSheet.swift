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

    /// The transfer station's real coordinate. A transfer segment's own stationStops is always
    /// empty by construction — the coordinate lives on the ride segment that follows it (same
    /// station, matched by ID with a defensive first-stop fallback).
    private var transferStopCoordinate: CLLocationCoordinate2D? {
        let stop = nextTransitSegment?.stationStops.first { $0.stationID == transferSegment.toStationID }
            ?? nextTransitSegment?.stationStops.first
        return stop?.coordinate.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
    }

    /// What entrances without a sign letter are described relative to. Nil is handled — those
    /// entrances fall back to a plain "station entrance" rather than an empty row.
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
                // Exits/corridor/platform guidance and official landing pages are keyed by
                // station NAME in the pack, so they still resolve when matchingStation found
                // no full record (a minimal name+coordinate station suffices for the lookup).
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
            // Street view keys off the route's own coordinate first so it still works when the
            // official pack doesn't list this station (matchingStation returned nil above).
            if let coordinate = transferStopCoordinate ?? enrichedStation?.coordinate,
               CLLocationCoordinate2DIsValid(coordinate),
               coordinate.latitude != 0 || coordinate.longitude != 0 {
                lookAroundScene = try? await MKLookAroundSceneRequest(coordinate: coordinate).scene
            }
        }
    }

    /// The whole instruction — which line, which direction, how long the walk — beside the badge
    /// of the line to look for.
    ///
    /// A separate header above this card repeated the station name that the navigation bar was
    /// already showing, one line apart, and put the onward line in a capsule the ride card then
    /// named again in text. Two renderings of two facts, in the place where a rider has the least
    /// attention to spare.
    private var rideSection: some View {
        GlassCard {
            HStack(alignment: .top, spacing: 12) {
                if let nextSegment = nextTransitSegment, let lineName = nextSegment.lineName {
                    LineBadge(name: lineName, colorHex: nextSegment.lineColorHex, size: 34)
                }
                VStack(alignment: .leading, spacing: 6) {
                    if let nextSegment = nextTransitSegment,
                       let lineName = nextSegment.lineName, let toward = nextSegment.toStationName {
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
                }
            }
        }
    }

    /// The in-station walkthrough riders (especially less sign-savvy ones) ask for: which
    /// exits/entrances exist, the transfer corridor, and boarding car/door hints — each
    /// The station's exits. What used to sit here was a "Transfer Guide" — a heading, a
    /// confidence chip that read `unknown` on every route in the app, a sentence apologising for
    /// having no exit data, and rows for corridor and platform hints. Not one of the 58 bundled
    /// packs carries an `interchangeHints` or `platformHints` entry, and none ever has: the card
    /// promised to tell riders how to make the change and had nothing to say. The exits are real
    /// — 329 of Guangzhou's 329 stations carry them — so they stay, as themselves.
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
        // Drawn only when there is something to link to. This card previously rendered a title
        // followed by "No official station resources are listed for this station" — a named
        // feature reporting its own absence, in the middle of a transfer a rider is walking. The
        // Transfer Guide below already carries the provenance chip that says what is and is not
        // known about this station, so nothing honest is lost by leaving the empty case out.
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
                        english: "These official resources are displayed inside Just-Go. Just-Go does not verify or interpret what they show.",
                        simplified: "这些官方资源会在 Just-Go 内显示；Just-Go 不对其内容作核实或解读。",
                        traditional: "這些官方資源會在 Just-Go 內顯示；Just-Go 不對其內容作核實或解讀。"
                    ))
                        .rowMeta()
                }
            }
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

    /// Apple's Look Around has no coverage underground, so this can only ever show the
    /// station's street-level entrance, not the platform itself — the caption makes that
    /// explicit. Renders nothing when no coverage exists for the coordinate.
    @ViewBuilder
    private var lookAroundSection: some View {
        if let lookAroundScene {
            VStack(alignment: .leading, spacing: 6) {
                LookAroundPreview(initialScene: lookAroundScene)
                    .frame(height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
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

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
