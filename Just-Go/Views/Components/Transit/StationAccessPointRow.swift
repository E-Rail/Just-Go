import SwiftUI

/// One entrance row, a named exit or a counted group of unlabeled entrances facing one direction,
/// shared by the station sheet and the transfer sheet so the two render it identically.
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
            // Three states, and only two say anything. `.unknown` is most doors in every
            // OSM-sourced pack; labelling it would turn "nobody has looked" into "not step-free".
            switch group.stepFree {
            case .yes:
                Text(AppLocalization.text(english: "Step-free", simplified: "无障碍", traditional: "無障礙"))
                    .font(.caption2)
                    .foregroundStyle(.green)
            case .no:
                Text(AppLocalization.text(
                    english: "Not step-free",
                    simplified: "非无障碍",
                    traditional: "非無障礙"
                ))
                .font(.caption2)
                .foregroundStyle(.secondary)
            case .unknown:
                EmptyView()
            }
            Spacer()
        }
    }
}
