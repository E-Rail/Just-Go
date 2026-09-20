import CoreLocation
import SwiftUI

/// One metro line: where it runs, and every station it calls at. All from the bundled OSM network,
/// so it works offline, spends no quota and is the data the router plans on. The operator check at
/// the bottom answers what the pack cannot: whether it is still current.
struct LineDetailView: View {
    let cityID: String
    let lineID: String

    @Environment(DIContainer.self) private var container
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var line: MetroLine?
    @State private var stationsByID: [String: Station] = [:]
    @State private var visibleRegion: MapVisibleRegion?
    @State private var isLoading = true
    @State private var selectedPatternIndex = 0
    @State private var observed: ObservedLine?
    @State private var observationState: ObservationState = .idle

    private enum ObservationState: Equatable {
        case idle
        case checking
        /// The operator's routing had nothing to say about this line (a ring or a very short line
        /// does that). Distinct from `.idle` so the button does not invite a second call that fails
        /// the same way.
        case unavailable
        case answered
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let line {
                content(for: line)
            } else {
                unavailableNotice
            }
        }
        .background(Color.appBackground)
        .navigationTitle(line.map { LineNaming.localizedName(of: $0) } ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    // MARK: - Layout

    /// Side by side when there is width, stacked otherwise, so an iPad does not put the stops a
    /// screen below their line.
    @ViewBuilder
    private func content(for line: MetroLine) -> some View {
        if horizontalSizeClass == .regular {
            // The stop list gets a measured width (see `sideColumn(max:in:)`); left to infer one,
            // it renders as nothing.
            GeometryReader { geo in
                HStack(spacing: 0) {
                    map(for: line)
                        .frame(maxWidth: .infinity)
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: Metrics.l) {
                            header(for: line)
                            serviceVariants(for: line)
                            stopList(for: line)
                            operatorCheck(for: line)
                        }
                        .padding(Metrics.l)
                    }
                    .sideColumn(max: Metrics.stopColumnWidth, in: geo.size.width)
                }
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.l) {
                    map(for: line)
                        .frame(height: 260)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
                    header(for: line)
                    serviceVariants(for: line)
                    stopList(for: line)
                    operatorCheck(for: line)
                }
                .padding(Metrics.l)
                .readableColumn()
            }
        }
    }

    /// One line becomes a network of one line, so this page draws with the browse map's renderer,
    /// strokes and markers.
    private func map(for line: MetroLine) -> some View {
        TransitMapView(
            visibleRegion: $visibleRegion,
            stations: orderedStations(for: line),
            alwaysShowsStations: true,
            metroNetworks: [singleLineNetwork(for: line)],
            route: nil,
            showsUserLocation: false,
            // Heavier than the browse map's, which is set so a dozen crossing lines stay separable.
            networkLineWidth: 9,
            onRegionChanged: nil,
            onStationSelected: { _ in }
        )
        .overlay(alignment: .bottomLeading) {
            // ODbL: every screen that draws this geometry has to say where it came from.
            MetroGeometryAttributionView()
                .padding(8)
        }
    }

    /// Other trains on this line: an express that skips stops, a short-turn that ends part way.
    /// Shown, never routed on: OpenStreetMap publishes each as a relation with no `opening_hours`,
    /// `interval` or `frequency`, so the stop count is stated and the timing is not.
    @ViewBuilder
    private func serviceVariants(for line: MetroLine) -> some View {
        let variants = line.serviceVariants ?? []
        if !variants.isEmpty {
            GlassCard {
                VStack(alignment: .leading, spacing: Metrics.s) {
                    Text(AppLocalization.text(
                        english: "Other trains on this line",
                        simplified: "本线其他车次",
                        traditional: "本線其他車次"
                    ))
                    .rowTitle()
                    ForEach(variants) { variant in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(variant.kind)
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Text(AppLocalization.text(
                                english: "Calls at \(variant.stationIDs.count) of this line's \(line.stationIDs.count) stations",
                                simplified: "停靠本线 \(line.stationIDs.count) 站中的 \(variant.stationIDs.count) 站",
                                traditional: "停靠本線 \(line.stationIDs.count) 站中的 \(variant.stationIDs.count) 站"
                            ))
                            .rowMeta()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text(AppLocalization.text(
                        english: "Timetables for these are not published, so routes are planned on the all-stops service.",
                        simplified: "这些车次没有公开时刻表，因此路线按站站停车次规划。",
                        traditional: "這些車次沒有公開時刻表，因此路線按站站停車次規劃。"
                    ))
                    .rowMeta()
                }
            }
        }
    }

    private func header(for line: MetroLine) -> some View {
        let patterns = line.servicePatterns
        return VStack(alignment: .leading, spacing: Metrics.s) {
            HStack(spacing: Metrics.s) {
                RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                    .fill(Color(hex: line.colorHex))
                    .frame(width: 34, height: 6)
                Text(terminalSummary(for: line))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }

            Text(stationCountLabel(for: line))
                .font(.title3.weight(.semibold))

            if patterns.count > 1 {
                // A line with more than one pattern is branched or split (35 of the 372 bundled
                // lines); name the branches rather than silently show one.
                Picker("", selection: $selectedPatternIndex) {
                    ForEach(patterns.indices, id: \.self) { index in
                        Text(branchLabel(for: patterns[index])).tag(index)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                // The operator answer is true only of the branch it was asked about, so switching
                // branches clears it: first and last trains attributed to the wrong arm are a
                // missed-last-train error.
                .onChange(of: selectedPatternIndex) { _, _ in
                    observed = nil
                    observationState = .idle
                }
            }
        }
    }

    private func stopList(for line: MetroLine) -> some View {
        let pattern = activePattern(of: line)
        return GlassCard {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(pattern.enumerated()), id: \.offset) { index, stationID in
                    let station = stationsByID[stationID]
                    HStack(spacing: Metrics.m) {
                        LineColorIndicator(colorHex: line.colorHex)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(station?.localizedName ?? stationID)
                                .rowTitle()
                            if let alternate = station?.alternateLocalizedName {
                                Text(alternate).rowMeta()
                            }
                        }
                        Spacer(minLength: 0)
                        if station?.isTransferStation == true {
                            Image(systemName: "arrow.triangle.swap")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel(AppLocalization.text(
                                    english: "Transfer station",
                                    simplified: "换乘站",
                                    traditional: "換乘站"
                                ))
                        }
                    }
                    .frame(minHeight: Metrics.minimumTapTarget)
                    if index < pattern.count - 1 {
                        // Starts at the station name: the line's colour dot plus the gap after it.
                        RowSeparator(textInset: 10 + Metrics.m)
                    }
                }
            }
        }
    }

    // MARK: - The operator check

    @ViewBuilder
    private func operatorCheck(for line: MetroLine) -> some View {
        VStack(alignment: .leading, spacing: Metrics.s) {
            switch observationState {
            case .idle:
                Button {
                    Task { await checkAgainstOperator(line) }
                } label: {
                    Label(
                        AppLocalization.text(
                            english: "Check against the operator",
                            simplified: "与运营方核对",
                            traditional: "與營運方核對"
                        ),
                        systemImage: "arrow.trianglehead.2.clockwise"
                    )
                }
                .buttonStyle(.bordered)
                .frame(minHeight: Metrics.minimumTapTarget)

            case .checking:
                ProgressView().frame(minHeight: Metrics.minimumTapTarget)

            case .unavailable:
                Text(AppLocalization.text(
                    english: "The routing service has nothing to say about this line. Ring lines and very short lines both return nothing.",
                    simplified: "路线服务没有这条线路的信息。环线和很短的线路都查不到。",
                    traditional: "路線服務沒有這條線路的資訊。環線和很短的線路都查不到。"
                ))
                .rowMeta()

            case .answered:
                if let observed {
                    observedSummary(observed, against: line)
                }
            }
        }
    }

    @ViewBuilder
    private func observedSummary(_ observed: ObservedLine, against line: MetroLine) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Metrics.s) {
                if let first = observed.firstTrain, let last = observed.lastTrain {
                    LabeledContent(AppLocalization.text(
                        english: "First and last train",
                        simplified: "首末班车",
                        traditional: "首末班車"
                    )) {
                        Text("\(first) – \(last)")
                    }
                    .rowTitle()
                }
                if let direction = observed.directionText, !direction.isEmpty {
                    LabeledContent(AppLocalization.text(
                        english: "Direction",
                        simplified: "方向",
                        traditional: "方向"
                    )) { Text(direction) }
                        .rowTitle()
                }

                let bundled = activePattern(of: line).count
                if observed.stops.count > bundled {
                    Text(AppLocalization.text(
                        english: "The operator lists \(observed.stops.count) stops on this stretch and this app holds \(bundled). The bundled map is behind.",
                        simplified: "运营方在这一段列出 \(observed.stops.count) 站，本应用只有 \(bundled) 站。离线地图数据已经落后。",
                        traditional: "營運方在這一段列出 \(observed.stops.count) 站，本應用只有 \(bundled) 站。離線地圖資料已經落後。"
                    ))
                    .rowMeta()
                }

                Text(AppLocalization.text(
                    english: "Checked just now. Nothing here is saved.",
                    simplified: "刚刚核对。此处内容不会保存。",
                    traditional: "剛剛核對。此處內容不會儲存。"
                ))
                .rowMeta()
            }
        }
    }

    private func checkAgainstOperator(_ line: MetroLine) async {
        guard let provider = container.lineObservationProvider else {
            observationState = .unavailable
            return
        }
        let pattern = activePattern(of: line)
        guard let first = pattern.first.flatMap({ stationsByID[$0] }),
              let last = pattern.last.flatMap({ stationsByID[$0] }),
              first.id != last.id else {
            // `first == last` is how a ring closes in a pattern, and routing a station to itself
            // asks nothing.
            observationState = .unavailable
            return
        }

        observationState = .checking
        let answer = await provider.observedLine(
            from: first.coordinate,
            to: last.coordinate,
            named: line.name
        )
        observed = answer
        observationState = answer == nil ? .unavailable : .answered
    }

    // MARK: - Data

    private func load() async {
        guard line == nil else { return }
        let network = await container.metroNetworkProvider.network(for: cityID)
        guard let network, let match = network.lines.first(where: { $0.id == lineID }) else {
            isLoading = false
            return
        }
        // Keyed by the raw network station id, which `servicePatterns` holds; a displayed
        // `Station.id` is qualified with the city and would silently match nothing. From the cached
        // stations, not a fresh `displayStations`, which rebuilds every station in the city.
        stationsByID = Dictionary(
            zip(network.stations.map(\.id), await container.metroNetworkProvider.stations(in: cityID)),
            uniquingKeysWith: { first, _ in first }
        )
        visibleRegion = MapVisibleRegion(
            fitting: match.paths.flatMap { $0 }.map {
                CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
            }
        )
        line = match
        isLoading = false
    }

    private func activePattern(of line: MetroLine) -> [String] {
        let patterns = line.servicePatterns
        guard !patterns.isEmpty else { return line.stationIDs }
        return patterns[min(selectedPatternIndex, patterns.count - 1)]
    }

    private func orderedStations(for line: MetroLine) -> [Station] {
        activePattern(of: line).compactMap { stationsByID[$0] }
    }

    /// A network carrying this line alone, so the map draws one line rather than the whole city.
    private func singleLineNetwork(for line: MetroLine) -> MetroNetwork {
        MetroNetwork(
            cityID: cityID,
            version: "line-\(line.id)",
            bounds: MetroBounds(minLatitude: -90, minLongitude: -180, maxLatitude: 90, maxLongitude: 180),
            geometryKind: "physicalTrack",
            lines: [line],
            stations: [],
            interchanges: []
        )
    }

    // MARK: - Text

    private func terminalSummary(for line: MetroLine) -> String {
        let pattern = activePattern(of: line)
        guard let first = pattern.first.flatMap({ stationsByID[$0]?.localizedName }),
              let last = pattern.last.flatMap({ stationsByID[$0]?.localizedName }) else {
            return ""
        }
        if first == last {
            return AppLocalization.text(english: "Loop line", simplified: "环线", traditional: "環線")
        }
        return "\(first) ↔ \(last)"
    }

    private func stationCountLabel(for line: MetroLine) -> String {
        let count = activePattern(of: line).count
        return AppLocalization.text(
            english: "\(count) stations",
            simplified: "\(count) 座车站",
            traditional: "\(count) 座車站"
        )
    }

    private func branchLabel(for pattern: [String]) -> String {
        guard let first = pattern.first.flatMap({ stationsByID[$0]?.localizedName }),
              let last = pattern.last.flatMap({ stationsByID[$0]?.localizedName }) else {
            return "\(pattern.count)"
        }
        return first == last ? AppLocalization.text(english: "Loop", simplified: "环", traditional: "環") : "\(first)–\(last)"
    }

    private var unavailableNotice: some View {
        ContentUnavailableView {
            Label(
                AppLocalization.text(
                    english: "Line unavailable",
                    simplified: "线路不可用",
                    traditional: "線路不可用"
                ),
                systemImage: "exclamationmark.triangle"
            )
        } description: {
            Text(AppLocalization.text(
                english: "This city's network is not loaded on this device.",
                simplified: "此城市的线网数据未在本机加载。",
                traditional: "此城市的線網資料未在本機載入。"
            ))
        }
    }
}

/// One rule for what a line is called on screen, shared by the line page, badges and route steps.
enum LineNaming {
    /// The same rule `Station.localizedName` follows, so a line and the stations on it cannot end
    /// up labelled in two different languages on one screen.
    static func localizedName(of line: MetroLine) -> String {
        AppLocalization.isChinese ? AppLocalization.chinese(line.name) : (line.nameEn ?? line.name)
    }
}
