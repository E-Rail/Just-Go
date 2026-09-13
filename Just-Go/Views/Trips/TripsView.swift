import SwiftUI

/// What the rider has put into this app, in one place.
///
/// Split out of Profile, which had become two unrelated things under one label: what the rider
/// owns and how the app behaves. Trips and saved places are the first of those; appearance, language, accessibility and data sources are the second. Only
/// the second is a profile.
///
/// One `NavigationStack` at the root and stack-free content underneath it. A `NavigationStack`
/// inside a pushed destination fails silently on iOS 18, which is why `QuickTagsView` takes an
/// `embedded` flag rather than carrying its own.
struct TripsView: View {
    @Environment(TripMemoryService.self) private var tripMemoryService
    @Environment(AppState.self) private var appState

    private var thisMonthRecords: [TripRecord] {
        let calendar = Calendar.current
        let now = Date()
        return tripMemoryService.tripRecords.filter {
            calendar.isDate($0.createdAt, equalTo: now, toGranularity: .month)
        }
    }

    private func averageDuration(for records: [TripRecord]) -> Int? {
        let durations = records.map(\.plannedDuration)
        guard !durations.isEmpty else { return nil }
        return Int(durations.reduce(0, +) / Double(durations.count) / 60)
    }

    var body: some View {
        NavigationStack {
            List {
                Group {
                    statisticsSection
                    savedPlacesSection
                    historySection
                }
                .listRowBackground(Color.clear)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.appBackground)
            .navigationTitle(AppLocalization.text(english: "Trips", simplified: "行程", traditional: "行程"))
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: TripsDestination.self) { destination in
                switch destination {
                case .savedPlaces:
                    QuickTagsView(showsDoneButton: false, embedded: true)
                }
            }
        }
    }

    // MARK: - Statistics

    @ViewBuilder
    private var statisticsSection: some View {
        let monthRecords = thisMonthRecords
        let total = tripMemoryService.tripRecords.count
        if total > 0 {
            Section {
                HStack(spacing: 20) {
                    statistic(value: "\(total)", caption: AppLocalization.localized("Total trips"))
                    Divider().frame(height: 36)
                    statistic(value: "\(monthRecords.count)", caption: AppLocalization.localized("This month"))
                    if let average = averageDuration(for: monthRecords) {
                        Divider().frame(height: 36)
                        statistic(
                            value: AppLocalization.minutes(average),
                            caption: AppLocalization.localized("Avg duration")
                        )
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text(AppLocalization.localized("Your stats"))
            }
        }
    }

    private func statistic(value: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title2)
                .fontWeight(.bold)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Saved places

    private var savedPlacesSection: some View {
        Section {
            let tags = tripMemoryService.stationQuickTags
            if tags.isEmpty {
                NavigationLink(value: TripsDestination.savedPlaces) {
                    Text(AppLocalization.text(
                        english: "Add a place you go often",
                        simplified: "添加常去的地点",
                        traditional: "新增常去的地點"
                    ))
                    .foregroundStyle(.secondary)
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(tags) { tag in
                            Label(tag.kind.title, systemImage: tag.kind.icon)
                                .font(.footnote)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.accentColor.opacity(0.18), in: Capsule())
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .padding(.vertical, 2)
                }
                NavigationLink(value: TripsDestination.savedPlaces) {
                    Text(AppLocalization.text(
                        english: "Manage saved places",
                        simplified: "管理常用地点",
                        traditional: "管理常用地點"
                    ))
                }
            }
        } header: {
            Text(AppLocalization.text(english: "Saved places", simplified: "常用地点", traditional: "常用地點"))
        }
    }

    // MARK: - History

    private var historySection: some View {
        Section {
            if tripMemoryService.tripRecords.isEmpty {
                Text(AppLocalization.localized("No trip history yet"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(tripMemoryService.tripRecords) { record in
                    tripRow(record)
                        .listSeparatorAtRowLeading()
                        .swipeActions {
                            Button(role: .destructive) {
                                tripMemoryService.deleteTripRecord(id: record.id)
                            } label: {
                                Label(AppLocalization.localized("Delete"), systemImage: "trash")
                            }
                        }
                }
            }
        } header: {
            Text(AppLocalization.localized("Trip History"))
        } footer: {
            Text(AppLocalization.localized("Saved locally on this device."))
        }
    }

    @ViewBuilder
    private func tripRow(_ record: TripRecord) -> some View {
        let content = VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(record.originName) → \(record.destinationName)")
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if record.isCompleted {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }

            HStack(spacing: 12) {
                Label(AppLocalization.minutes(Int(record.plannedDuration / 60)), systemImage: "clock")
                Label(AppLocalization.transfers(record.transferCount), systemImage: "arrow.triangle.2.circlepath")
                Label(AppLocalization.distance(record.walkingDistance), systemImage: "figure.walk")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            // `routeSummary` is a frozen, locale-stamped duration string and duplicates the
            // localized duration above; the strategy alone follows the current language.
            Text(record.strategy.localizedName)
                .font(.caption)
                .foregroundStyle(.secondary)
            if !record.warningMessages.isEmpty {
                Text(record.warningMessages.prefix(2).joined(separator: "; "))
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let note = record.note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)

        // Only rows that carry both station IDs can be planned again. Older rows kept names only,
        // and re-matching a trip by name is exactly the guess this app does not make.
        if record.canReplan {
            Button {
                replan(record)
            } label: {
                HStack {
                    content
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(AppLocalization.text(
                english: "Plans this trip again",
                simplified: "重新规划这次行程",
                traditional: "重新規劃這次行程"
            ))
        } else {
            content
        }
    }

    private func replan(_ record: TripRecord) {
        guard let origin = record.originStationID, let destination = record.destinationStationID else { return }
        appState.pendingTripReplay = AppState.PendingTripReplay(
            cityID: record.cityID,
            originStationID: origin,
            destinationStationID: destination
        )
        appState.selectedTab = .map
    }

}

enum TripsDestination: Hashable {
    case savedPlaces
}
