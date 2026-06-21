import SwiftUI

struct FavoriteStationsView: View {
    @Environment(TripMemoryService.self) private var tripMemoryService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if tripMemoryService.favoriteStations.isEmpty {
                    Text(AppLocalization.localized("No favorite stations yet"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(tripMemoryService.favoriteStations) { favorite in
                        NavigationLink(destination: StationDetailView(station: favorite.toStation())) {
                            HStack(spacing: 12) {
                                Image(systemName: "star.fill")
                                    .foregroundStyle(.yellow)
                                    .frame(width: 24)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(favorite.name)
                                        .font(.headline)
                                    Text(favorite.cityName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if !favorite.lineNames.isEmpty {
                                        Text(favorite.lineNames.joined(separator: " • "))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                tripMemoryService.removeFavorite(id: favorite.id)
                            } label: {
                                Label(AppLocalization.localized("Remove"), systemImage: "star.slash")
                            }
                        }
                    }
                }
            }
            .navigationTitle(AppLocalization.localized("My Stations"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppLocalization.localized("Done")) { dismiss() }
                }
            }
        }
    }
}
