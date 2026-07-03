import SwiftUI

private struct LineStatus: Identifiable {
    var id: String { line.id }
    let line: MetroLine
    let status: RouteServiceStatus
}

struct NetworkLineStatusView: View {
    let cityID: String

    @Environment(DIContainer.self) private var container
    @State private var lineStatuses: [LineStatus] = []
    @State private var isLoading = false
    @State private var asOfText = ""
    @State private var refreshID = UUID()
    @State private var loadGeneration = UUID()

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if lineStatuses.isEmpty {
                    ContentUnavailableView {
                        Label(
                            AppLocalization.text(english: "No Lines", simplified: "暂无线路", traditional: "暫無線路"),
                            systemImage: "tram"
                        )
                    } description: {
                        Text(AppLocalization.text(
                            english: "No metro lines found for this city.",
                            simplified: "未找到此城市的地铁线路。",
                            traditional: "未找到此城市的地鐵線路。"
                        ))
                    }
                } else {
                    List {
                        ForEach(lineStatuses) { item in
                            HStack(spacing: 12) {
                                Circle()
                                    .fill(Color(hex: item.line.colorHex))
                                    .frame(width: 14, height: 14)

                                Text(item.line.localizedName)
                                    .font(.body)

                                Spacer()

                                Image(systemName: item.status.iconName)
                                    .foregroundStyle(item.status.uiColor)

                                if let text = item.status.bannerText {
                                    Text(text)
                                        .font(.caption)
                                        .foregroundStyle(item.status.uiColor)
                                        .lineLimit(1)
                                }
                            }
                        }

                        if !asOfText.isEmpty {
                            Text(AppLocalization.text(
                                english: "As of \(asOfText)",
                                simplified: "截至 \(asOfText)",
                                traditional: "截至 \(asOfText)"
                            ))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .listRowSeparator(.hidden)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .background(Color.appBackground)
            .navigationTitle(AppLocalization.text(english: "Line Status", simplified: "线路状态", traditional: "線路狀態"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        refreshID = UUID()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isLoading)
                }
            }
        }
        .task(id: refreshID) {
            await loadLineStatuses()
        }
    }

    private func loadLineStatuses() async {
        guard !cityID.isEmpty else { return }
        let generation = UUID()
        loadGeneration = generation
        isLoading = true
        defer {
            if loadGeneration == generation && !Task.isCancelled {
                isLoading = false
            }
        }

        guard let network = await container.metroNetworkProvider.network(for: cityID) else { return }
        guard loadGeneration == generation, !Task.isCancelled else { return }

        let stationsByID = Dictionary(network.stations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var results: [LineStatus] = []
        await withTaskGroup(of: LineStatus?.self) { group in
            for line in network.lines {
                group.addTask {
                    let repStationID = line.servicePatterns.first?.first ?? line.stationIDs.first
                    guard let stationID = repStationID,
                          let metroStation = stationsByID[stationID] else {
                        return LineStatus(line: line, status: .unknown)
                    }
                    let windows = await container.officialStationData.serviceWindows(
                        cityID: cityID,
                        stationName: metroStation.name
                    )
                    let status = ServiceHoursResolver().status(boardingLineName: line.name, windows: windows, at: Date())
                    return LineStatus(line: line, status: status)
                }
            }
            for await item in group {
                guard !Task.isCancelled else { continue }
                if let item { results.append(item) }
            }
        }

        guard loadGeneration == generation, !Task.isCancelled else { return }
        results.sort {
            let n0 = $0.line.name.components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap(Int.init).first ?? 0
            let n1 = $1.line.name.components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap(Int.init).first ?? 0
            if n0 != n1 { return n0 < n1 }
            return $0.line.name < $1.line.name
        }
        guard loadGeneration == generation, !Task.isCancelled else { return }
        lineStatuses = results
        asOfText = ChinaClock.clockText(Date())
    }
}
