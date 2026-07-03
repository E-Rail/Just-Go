import SwiftUI
import CoreLocation
import MapKit

struct TransferStationSheet: View {
    let transferSegment: RouteSegment
    let nextTransitSegment: RouteSegment?
    let cityID: String
    let crowdControl: RouteCrowdControl

    @Environment(DIContainer.self) private var container
    @State private var enrichedStation: Station?
    @State private var isLoadingStation = false
    @State private var lookAroundScene: MKLookAroundScene?

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
                lookAroundSection
                transferTimeSection
                accessibilitySection
                if !crowdWindows.isEmpty {
                    crowdControlSection
                }
                if let nextSegment = nextTransitSegment {
                    directionSection(nextSegment: nextSegment)
                }
            }
            .padding()
        }
        .background(Color.appBackground)
        .navigationTitle(stationName)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            isLoadingStation = true
            defer { isLoadingStation = false }
            // Match by the real transfer-station coordinate when the route carries one — a
            // (0,0) placeholder makes same-named stations disambiguate by distance to Null
            // Island and picks an arbitrary one.
            let place = TransitPlace(
                name: stationName,
                coordinate: transferStopCoordinate ?? CLLocationCoordinate2D(latitude: 0, longitude: 0),
                source: .localStationData
            )
            enrichedStation = await container.officialStationData.matchingStation(place: place, cityID: cityID)
            // Street view keys off the route's own coordinate first so it still works when the
            // official pack doesn't list this station (matchingStation returned nil above).
            if let coordinate = transferStopCoordinate ?? enrichedStation?.coordinate,
               CLLocationCoordinate2DIsValid(coordinate),
               coordinate.latitude != 0 || coordinate.longitude != 0 {
                lookAroundScene = try? await MKLookAroundSceneRequest(coordinate: coordinate).scene
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

    private var transferTimeSection: some View {
        GlassCard {
            HStack {
                Label(
                    AppLocalization.text(english: "Transfer Time", simplified: "换乘时间", traditional: "換乘時間"),
                    systemImage: "figure.walk"
                )
                .font(.subheadline)
                .fontWeight(.medium)
                Spacer()
                Text(transferSegment.formattedDuration)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

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
                    accessibilityRow(
                        title: AppLocalization.text(english: "Elevator", simplified: "电梯", traditional: "電梯"),
                        icon: "arrow.up.arrow.down.circle.fill",
                        available: acc?.hasElevator
                    )
                    accessibilityRow(
                        title: AppLocalization.text(english: "Ramp", simplified: "坡道", traditional: "坡道"),
                        icon: "figure.roll",
                        available: acc?.hasWheelchairRamp
                    )

                    let accessibleRestroom = station.facilities.first { $0.type == .accessibleRestroom }
                    accessibilityRow(
                        title: AppLocalization.text(english: "Accessible Restroom", simplified: "无障碍卫生间", traditional: "無障礙廁所"),
                        icon: "toilet",
                        available: accessibleRestroom != nil ? true : nil
                    )
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

    private func accessibilityRow(title: String, icon: String, available: Bool?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(available == true ? .green : available == false ? .red : .secondary)
                .frame(width: 18)
            Text(title)
                .font(.caption)
            Spacer()
            if let available {
                Image(systemName: available ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(available ? .green : .red)
            } else {
                Image(systemName: "questionmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
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

    private func directionSection(nextSegment: RouteSegment) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 4) {
                Text(AppLocalization.text(english: "Onward Direction", simplified: "前往方向", traditional: "前往方向"))
                    .font(.subheadline)
                    .fontWeight(.medium)

                if let lineName = nextSegment.lineName, let toward = nextSegment.toStationName {
                    Text(AppLocalization.text(
                        english: "Board \(lineName) toward \(toward)",
                        simplified: "乘\(lineName)方向 \(toward)",
                        traditional: "乘\(lineName)方向 \(toward)"
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }
}
