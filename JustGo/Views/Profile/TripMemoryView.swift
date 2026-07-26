import SwiftUI

struct TripMemoryView: View {
    @Environment(TripMemoryService.self) private var tripMemoryService
    @Environment(\.dismiss) private var dismiss

    private var thisMonthRecords: [TripRecord] {
        let cal = Calendar.current
        let now = Date()
        return tripMemoryService.tripRecords.filter {
            cal.isDate($0.createdAt, equalTo: now, toGranularity: .month)
        }
    }

    private var mostUsedTrip: SavedTrip? {
        tripMemoryService.savedTrips.max(by: { $0.useCount < $1.useCount })
    }

    private func avgMonthlyDuration(for records: [TripRecord]) -> Int? {
        let durations = records.map(\.plannedDuration)
        guard !durations.isEmpty else { return nil }
        return Int(durations.reduce(0, +) / Double(durations.count) / 60)
    }

    @ViewBuilder
    private var statisticsCard: some View {
        // Computed once and reused below instead of letting thisMonthRecords (a full filter
        // pass over tripRecords) run twice per render — once for the count, once inside what
        // was a second computed property re-deriving the average from the same filter.
        let monthRecords = thisMonthRecords
        let monthCount = monthRecords.count
        let totalCount = tripMemoryService.tripRecords.count
        if totalCount > 0 {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 20) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(totalCount)")
                                .font(.title2)
                                .fontWeight(.bold)
                            Text(AppLocalization.localized("Total trips"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Divider()
                            .frame(height: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(monthCount)")
                                .font(.title2)
                                .fontWeight(.bold)
                            Text(AppLocalization.localized("This month"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let avg = avgMonthlyDuration(for: monthRecords) {
                            Divider()
                                .frame(height: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(AppLocalization.minutes(avg))
                                    .font(.title2)
                                    .fontWeight(.bold)
                                Text(AppLocalization.localized("Avg duration"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let top = mostUsedTrip, top.useCount > 0 {
                        Divider()
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.trianglehead.clockwise")
                                .font(.caption)
                                .foregroundStyle(Color.accentColor)
                            Text(AppLocalization.text(
                                english: "Most used: \(top.name) (\(top.useCount)×)",
                                simplified: "最常用：\(top.name)（\(top.useCount)次）",
                                traditional: "最常用：\(top.name)（\(top.useCount)次）"
                            ))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text(AppLocalization.localized("Your stats"))
            }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Group {
                    statisticsCard
                    Section {
                        if tripMemoryService.savedTrips.isEmpty {
                            Text(AppLocalization.localized("No saved trips yet"))
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(tripMemoryService.savedTrips) { trip in
                                HStack(alignment: .top, spacing: 12) {
                                    Image(systemName: "bookmark.fill")
                                        .foregroundStyle(Color.accentColor)
                                        .frame(width: 24)

                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(trip.name)
                                            .font(.headline)
                                        Text(trip.routeTitle)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                        Text(AppLocalization.text(
                                            english: "Used \(trip.useCount) times",
                                            chinese: "已使用\(trip.useCount)次"
                                        ))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.vertical, 8)
                                .swipeActions {
                                    Button(role: .destructive) {
                                        tripMemoryService.deleteSavedTrip(id: trip.id)
                                    } label: {
                                        Label(AppLocalization.localized("Delete"), systemImage: "trash")
                                    }
                                }
                            }
                        }
                    } header: {
                        Text(AppLocalization.localized("Saved Trips"))
                    }

                    Section {
                        if tripMemoryService.tripRecords.isEmpty {
                            Text(AppLocalization.localized("No trip history yet"))
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(tripMemoryService.tripRecords) { record in
                                VStack(alignment: .leading, spacing: 8) {
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

                                    // routeSummary is a frozen, locale-stamped duration string and
                                    // duplicates the localized duration already shown above; show the
                                    // strategy alone so it follows the current language.
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
                .listRowBackground(Color.clear)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.appBackground)
            .navigationTitle(AppLocalization.localized("My Trips"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppLocalization.localized("Done")) { dismiss() }
                }
            }
        }
    }
}
