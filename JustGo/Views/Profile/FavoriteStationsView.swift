import SwiftUI

struct FavoriteStationsView: View {
    @Environment(TripMemoryService.self) private var tripMemoryService
    @Environment(DIContainer.self) private var container
    @Environment(\.dismiss) private var dismiss
    @State private var tagEditingFavorite: FavoriteStation?
    @State private var customTagFavorite: FavoriteStation?
    @State private var customTagText = ""

    private var tagActionTitle: String {
        AppLocalization.text(english: "Tag", simplified: "标签", traditional: "標籤")
    }

    var body: some View {
        NavigationStack {
            List {
                if tripMemoryService.favoriteStations.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "star.circle")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text(AppLocalization.localized("No favorite stations yet"))
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Text(AppLocalization.localized("Find a station in Search or Map, then tap the star to save it here."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                } else {
                    ForEach(tripMemoryService.favoriteStations) { favorite in
                        NavigationLink(destination: StationDetailView(station: favorite.toStation())) {
                            favoriteRow(favorite)
                        }
                        .swipeActions(edge: .leading) {
                            Button {
                                tagEditingFavorite = favorite
                            } label: {
                                Label(tagActionTitle, systemImage: "tag")
                            }
                            .tint(.accentColor)
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                tripMemoryService.removeFavorite(id: favorite.id)
                            } label: {
                                Label(AppLocalization.localized("Remove"), systemImage: "star.slash")
                            }
                        }
                        .contextMenu {
                            Button {
                                tagEditingFavorite = favorite
                            } label: {
                                Label(tagActionTitle, systemImage: "tag")
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .background(Color.appBackground)
            .navigationTitle(AppLocalization.localized("My Stations"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppLocalization.localized("Done")) { dismiss() }
                }
            }
            .confirmationDialog(
                tagEditingFavorite?.displayName ?? tagActionTitle,
                isPresented: Binding(
                    get: { tagEditingFavorite != nil },
                    set: { if !$0 { tagEditingFavorite = nil } }
                ),
                titleVisibility: .visible,
                presenting: tagEditingFavorite
            ) { favorite in
                Button(FavoriteStationTag.home.title) {
                    tripMemoryService.setFavoriteTag(id: favorite.id, tag: .home)
                }
                Button(FavoriteStationTag.work.title) {
                    tripMemoryService.setFavoriteTag(id: favorite.id, tag: .work)
                }
                Button(AppLocalization.text(english: "Custom…", simplified: "自定义…", traditional: "自訂…")) {
                    customTagText = ""
                    customTagFavorite = favorite
                }
                if favorite.tag != nil {
                    Button(AppLocalization.text(english: "Remove Tag", simplified: "移除标签", traditional: "移除標籤"), role: .destructive) {
                        tripMemoryService.setFavoriteTag(id: favorite.id, tag: nil)
                    }
                }
            } message: { _ in
                Text(AppLocalization.text(
                    english: "Tagged stations appear as quick-fill chips in the route planner.",
                    simplified: "已加标签的车站会显示在路线规划的快捷标签中。",
                    traditional: "已加標籤的車站會顯示在路線規劃的快捷標籤中。"
                ))
            }
            .alert(
                AppLocalization.text(english: "Custom Tag", simplified: "自定义标签", traditional: "自訂標籤"),
                isPresented: Binding(
                    get: { customTagFavorite != nil },
                    set: { if !$0 { customTagFavorite = nil } }
                ),
                presenting: customTagFavorite
            ) { favorite in
                TextField(
                    AppLocalization.text(english: "Tag name", simplified: "标签名称", traditional: "標籤名稱"),
                    text: $customTagText
                )
                Button(AppLocalization.localized("Save")) {
                    let label = customTagText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !label.isEmpty else { return }
                    tripMemoryService.setFavoriteTag(id: favorite.id, tag: .custom(label))
                }
                Button(AppLocalization.localized("Cancel"), role: .cancel) {}
            }
        }
        .task {
            tripMemoryService.repairFavoriteCityMetadata { cityID in
                container.cityService.getCity(byID: cityID)
            }
        }
    }

    private func favoriteRow(_ favorite: FavoriteStation) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "star.fill")
                .foregroundStyle(.yellow)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(favorite.displayName)
                    .font(.headline)
                Text(favorite.displayCityName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !favorite.lineNames.isEmpty {
                    Text(favorite.displayLineNames.joined(separator: " • "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let tag = favorite.tag {
                    Label(tag.title, systemImage: tag.icon)
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                }
            }
        }
        .padding(.vertical, 4)
    }
}
