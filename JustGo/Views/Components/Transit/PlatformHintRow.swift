import SwiftUI

/// The station-guidance rows shared by the station detail sheet and the transfer sheet, which
/// render them identically. Keeping them together is what stops the two screens drifting: the
/// transfer sheet printed access-point names raw and so showed a blank row for every entrance
/// OpenStreetMap positioned without a sign letter.

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

/// One platform-boarding hint (line · direction · car · door side, plus any notes).
struct PlatformHintRow: View {
    let hint: StationPlatformHint

    var body: some View {
        let parts = [hint.lineName, hint.directionText, hint.boardingCarText, hint.doorSideText]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "tram.fill")
                .font(.caption)
                .foregroundStyle(Color.accentColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                if !parts.isEmpty {
                    Text(parts.joined(separator: " · "))
                        .font(.subheadline)
                }
                ForEach(hint.notes, id: \.self) { note in
                    Text(note)
                        .rowMeta()
                }
            }
            Spacer()
        }
    }
}
