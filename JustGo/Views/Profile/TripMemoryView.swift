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
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: "bookmark.fill")
                                    .foregroundStyle(.blue)
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

                                Text([record.routeSummary, record.strategy.localizedName].joined(separator: " • "))
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
