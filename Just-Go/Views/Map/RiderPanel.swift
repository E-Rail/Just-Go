import SwiftUI
import CoreLocation

/// What a rider opens the app for, over the map: the trip under way, the places they go, and the
/// station nearest them. Each is one tap from a result, where the map alone is a search away.
///
/// Minimizes to one line, and remembers it: a rider who came to look at the map gets the map.
struct RiderPanel: View {
    struct Trip {
        let title: String
        let detail: String?
    }

    struct NearestStation {
        let station: Station
        let distance: CLLocationDistance
    }

    let trip: Trip?
    let savedPlaces: [StationQuickTag]
    let nearest: NearestStation?
    let onOpenTrip: () -> Void
    let onSelectPlace: (StationQuickTag) -> Void
    let onAddPlace: () -> Void
    let onOpenStation: (Station) -> Void

    @AppStorage("riderPanelMinimized") private var isMinimized = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        VStack(spacing: 0) {
            if isMinimized {
                minimizedRow
            } else {
                expandedRows
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
        .elevated(.floating)
        // A column on a wide screen, where a panel the width of an iPad would cover the map it is
        // there to accompany. From the size class, so a narrow split-screen window keeps the bar.
        .frame(maxWidth: horizontalSizeClass == .regular ? Metrics.tripColumnWidth : .infinity)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .animation(.easeInOut(duration: 0.2), value: isMinimized)
    }

    // MARK: - Expanded

    @ViewBuilder
    private var expandedRows: some View {
        if let trip {
            tripRow(trip)
            Divider()
        }
        placesRow
        if let nearest {
            Divider()
            StationRow(
                station: nearest.station,
                distanceText: AppLocalization.distance(nearest.distance),
                action: { onOpenStation(nearest.station) }
            )
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
        }
    }

    private func tripRow(_ trip: Trip) -> some View {
        Button(action: onOpenTrip) {
            HStack(spacing: 12) {
                Image(systemName: "location.north.line.fill")
                    .font(.headline)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(AppLocalization.text(
                        english: "Trip in progress",
                        simplified: "行程进行中",
                        traditional: "行程進行中"
                    ))
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    Text([trip.title, trip.detail].compactMap { $0 }.joined(separator: " · "))
                        .rowMeta()
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(AppLocalization.text(english: "Opens guidance", simplified: "打开导航", traditional: "開啟導航"))
    }

    /// Saved places, each a trip from here in one tap, and the control that puts the panel away.
    /// The control sits on this row because this row is always present.
    private var placesRow: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    SavedPlaceChips(tags: savedPlaces, onSelect: onSelectPlace)
                    addPlaceChip
                }
                .padding(.leading, 14)
                .padding(.vertical, 10)
            }
            minimizeButton
        }
    }

    /// With nothing saved this is the row's whole content, so it says what saving buys.
    private var addPlaceChip: some View {
        Button(action: onAddPlace) {
            HStack(spacing: 5) {
                Image(systemName: "plus")
                    .font(.caption)
                if savedPlaces.isEmpty {
                    Text(AppLocalization.text(
                        english: "Save Home and Work to plan in one tap",
                        simplified: "保存家和公司，一键规划",
                        traditional: "儲存家和公司，一鍵規劃"
                    ))
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.accentColor.opacity(0.18), in: Capsule())
            .foregroundStyle(Color.accentColor)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(AppLocalization.text(english: "Add a saved place", simplified: "添加常用地点", traditional: "新增常用地點"))
    }

    // MARK: - Minimized

    /// One line: the trip under way, or else the nearest station, or else nothing but the way back.
    private var minimizedRow: some View {
        HStack(spacing: 4) {
            Group {
                if let trip {
                    Button(action: onOpenTrip) {
                        summary(icon: "location.north.line.fill", text: trip.title)
                    }
                } else if let nearest {
                    Button { onOpenStation(nearest.station) } label: {
                        summary(
                            icon: "tram.fill",
                            text: "\(nearest.station.localizedName) · \(AppLocalization.distance(nearest.distance))"
                        )
                    }
                } else {
                    Button { isMinimized = false } label: {
                        summary(
                            icon: "bookmark.fill",
                            text: AppLocalization.text(english: "Saved places", simplified: "常用地点", traditional: "常用地點")
                        )
                    }
                }
            }
            .buttonStyle(.plain)
            minimizeButton
        }
    }

    private func summary(icon: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)
            Text(text)
                .font(.subheadline)
                .fontWeight(.medium)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.leading, 14)
        .frame(minHeight: Metrics.minimumTapTarget)
        .contentShape(Rectangle())
    }

    private var minimizeButton: some View {
        Button {
            isMinimized.toggle()
        } label: {
            Image(systemName: isMinimized ? "chevron.up" : "chevron.down")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .tappable()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isMinimized
            ? AppLocalization.text(english: "Expand panel", simplified: "展开面板", traditional: "展開面板")
            : AppLocalization.text(english: "Minimize panel", simplified: "收起面板", traditional: "收起面板"))
    }
}
