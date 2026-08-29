import SwiftUI

/// The entrance row shared by the station detail sheet and the transfer sheet, which render it
/// identically. Keeping one definition is what stops the two screens drifting: the transfer sheet
/// printed access-point names raw and so showed a blank row for every entrance OpenStreetMap
/// positioned without a sign letter.
///
/// `PlatformHintRow` used to live here too. It is gone with the rest of the transfer guide. No
/// pack has ever carried a platform hint, and `validate_indoor_maps.rb` keeps it that way.

/// One entrance row: a named exit, or a counted group of unlabeled entrances facing one direction.
struct StationAccessPointRow: View {
    let group: StationAccessPointGroup

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: group.isAccessible ? "figure.roll" : "figure.walk")
                .foregroundStyle(group.isAccessible ? .green : Color.accentColor)
                .frame(width: 22)
            Text(group.listName)
                .font(.subheadline)
            if group.count > 1 {
                Text(verbatim: "×\(group.count)")
                    .rowMeta()
                    .accessibilityLabel(AppLocalization.text(
                        english: "\(group.count) entrances",
                        simplified: "\(group.count) 个出入口",
                        traditional: "\(group.count) 個出入口"
                    ))
            }
            if group.isAccessible {
                Text(AppLocalization.text(english: "Step-free", simplified: "无障碍", traditional: "無障礙"))
                    .font(.caption2)
                    .foregroundStyle(.green)
            }
            Spacer()
        }
    }
}
