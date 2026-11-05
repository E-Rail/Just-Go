import SwiftUI

/// The rider's saved places as chips. One rule for every screen that offers them (the map's panel,
/// search and Trips), so "Home" looks and behaves the same wherever it is tapped.
///
/// Only the chips, with no container: each screen lays them out beside its own controls.
struct SavedPlaceChips: View {
    let tags: [StationQuickTag]
    let onSelect: (StationQuickTag) -> Void

    var body: some View {
        ForEach(tags) { tag in
            Button {
                onSelect(tag)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: tag.kind.icon)
                        .font(.caption)
                    Text(tag.kind.title)
                        .font(.caption)
                        .fontWeight(.medium)
                        .lineLimit(1)
                }
                .chipSurface()
            }
            .buttonStyle(.plain)
            .accessibilityHint(AppLocalization.text(
                english: "Uses this saved place",
                simplified: "使用这个常用地点",
                traditional: "使用這個常用地點"
            ))
        }
    }
}
