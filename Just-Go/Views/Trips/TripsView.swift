import SwiftUI

/// What the rider has put into this app, in one place.
///
/// Split out of Profile, which had become two unrelated things under one label: what the rider
/// owns and how the app behaves. Trips, saved places and the answers a rider has volunteered are
/// the first of those; appearance, language, accessibility and data sources are the second. Only
/// the second is a profile.
///
/// One `NavigationStack` at the root and stack-free content underneath it. A `NavigationStack`
/// inside a pushed destination fails silently on iOS 18, which is why `QuickTagsView` and
/// `TransferAnswersView` both take an `embedded` flag rather than carrying their own.
struct TripsView: View {
    @Environment(TripMemoryService.self) private var tripMemoryService
    @Environment(DIContainer.self) private var container
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
                    answersSection
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
                case .answers:
                    TransferAnswersView()
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

    // MARK: - Answers

    private var answersSection: some View {
        Section {
            NavigationLink(value: TripsDestination.answers) {
                HStack {
                    Text(AppLocalization.text(
                        english: "What you've told us",
                        simplified: "你告诉过我们的",
                        traditional: "你告訴過我們的"
                    ))
                    Spacer()
                    Text("\(container.transferInsightService.allNotes.count + container.riderAnswerService.allAnswers.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } footer: {
            Text(AppLocalization.text(
                english: "Your answers about transfers. They stay on this phone.",
                simplified: "你对换乘的回答。只保存在本机。",
                traditional: "你對換乘的回答。只儲存在本機。"
            ))
        }
    }
}

enum TripsDestination: Hashable {
    case savedPlaces
    case answers
}

/// The answers a rider has volunteered, and the only place they can read them back.
///
/// `TransferInsightService.allNotes` has existed since the transfer prompt shipped, documented as
/// feeding "a future 'things you've told us' screen", and had no reader at all — while the control
/// that deletes them all has been in Settings the whole time. A rider could erase these without
/// ever being shown what they were erasing.
///
/// `TransferKey`'s fields are named `stationID` and `*LineID` but hold display names: the one place
/// that writes them builds the key from `step.fromStationName` and `step.lineName`. They are shown
/// as-is rather than resolved, and the names are not renamed here because `storageID` is built from
/// them and every answer already on a rider's phone is filed under it.
struct TransferAnswersView: View {
    @Environment(DIContainer.self) private var container

    var body: some View {
        List {
            let notes = container.transferInsightService.allNotes
            let answers = container.riderAnswerService.allAnswers
            if notes.isEmpty && answers.isEmpty {
                Section {
                    Text(AppLocalization.text(
                        english: "You have not answered any questions yet.",
                        simplified: "你还没有回答过任何问题。",
                        traditional: "你還沒有回答過任何問題。"
                    ))
                    .foregroundStyle(.secondary)
                }
            }
            if !answers.isEmpty {
                Section {
                    ForEach(answers, id: \.key.storageID) { record in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.stationName)
                                .font(.headline)
                            Text(questionText(for: record))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack(spacing: 6) {
                                Text(answerText(for: record.answer))
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                Text(record.recordedAt, style: .date)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text(AppLocalization.text(english: "Stations", simplified: "车站", traditional: "車站"))
                }
            }
            if !notes.isEmpty {
                Section {
                ForEach(notes, id: \.key.storageID) { note in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(note.key.stationID)
                            .font(.headline)
                        Text("\(note.key.fromLineID) → \(note.key.toLineID)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            Text(note.pace.title)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                            Text(note.recordedAt, style: .date)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                } header: {
                    Text(AppLocalization.localized("Transfer"))
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.appBackground)
        .navigationTitle(AppLocalization.text(
            english: "What you've told us",
            simplified: "你告诉过我们的",
            traditional: "你告訴過我們的"
        ))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func questionText(for record: RiderAnswerRecord) -> String {
        switch record.key.question {
        case .liftToPlatform:
            return AppLocalization.text(
                english: "Lift from the concourse to the platform",
                simplified: "站厅到站台的直梯",
                traditional: "車站大堂到月台的電梯"
            )
        case .exitSide:
            let exit = record.detail ?? ""
            return AppLocalization.text(
                english: "\(exit) came out on the right side",
                simplified: "\(exit)出来的方向",
                traditional: "\(exit)出來的方向"
            )
        }
    }

    private func answerText(for answer: RiderAnswer) -> String {
        switch answer {
        case .yes:
            return AppLocalization.text(english: "You said yes", simplified: "你说有", traditional: "你說有")
        case .no:
            return AppLocalization.text(english: "You said no", simplified: "你说没有", traditional: "你說沒有")
        case .didNotLook:
            return AppLocalization.text(
                english: "You didn't look",
                simplified: "你说没注意",
                traditional: "你說沒注意"
            )
        }
    }
}
