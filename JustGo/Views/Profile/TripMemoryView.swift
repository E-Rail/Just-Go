import SwiftUI

struct TripMemoryView: View {
    @Environment(TripMemoryService.self) private var tripMemoryService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if tripMemoryService.savedTrips.isEmpty {
                        Text(AppLocalization.localized("No saved trips yet"))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(tripMemoryService.savedTrips) { trip in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(trip.name)
                                    .font(.headline)
                                Text(trip.routeTitle)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Text(AppLocalization.text(
                                    english: "Used \(trip.useCount) times",
                                    chinese: "已使用\(trip.useCount)次"
                                ))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
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
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("\(record.originName) -> \(record.destinationName)")
                                        .font(.headline)
                                    Spacer()
                                    if record.isCompleted {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                    }
                                }
                                Text([record.routeSummary, record.strategy.localizedName].joined(separator: " • "))
                                    .font(.subheadline)
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
