import SwiftUI

/// The measurements the app is drawn on: spacing, radii, elevation. Decide them here, not at the
/// call site.
///
/// Named `Metrics` rather than `Layout` because SwiftUI exports a `Layout` protocol, and the
/// collision resolves silently to theirs.
enum Metrics {
    /// A four-point rhythm. Everything the app spaces should land on one of these.
    static let hairline: CGFloat = 2
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16

    /// The smallest square a finger can reliably hit; Apple's floor.
    static let minimumTapTarget: CGFloat = 44

    /// The trip column beside a map on regular width: wide enough for a journey row without
    /// wrapping, narrow enough to leave the map the larger half.
    ///
    /// A **cap**, not a width. Apply it through `sideColumn(max:)`: a folding phone reports regular
    /// width at 626 points, where a fixed 420 would leave the map 205.
    static let tripColumnWidth: CGFloat = 420

    /// The same cap for the stop list beside a line's map. Its own number because a list of station
    /// names needs less room than a journey row with a line badge and a duration.
    static let stopColumnWidth: CGFloat = 380

    /// How wide a column of text or cards may get before it stops being readable. 620 is all but
    /// inert on a folding phone's 626-point inner display, which is fine: 620 points of text is
    /// still readable.
    static let readableColumnWidth: CGFloat = 620
}

/// Three radii, chosen so the ladder reads as deliberate at a glance.
enum Radius {
    /// Chips, badges, small controls.
    static let small: CGFloat = 10
    /// Inner groupings and secondary panels.
    static let medium: CGFloat = 14
    /// Cards and sheets, the app's primary surface.
    static let large: CGFloat = 20
}

/// Two elevations. Anything that needs a third needs a different design instead.
enum Elevation {
    /// A surface sitting on the background. Carries no shadow; the surface colour does the work.
    case resting
    /// A surface floating over content, usually over the map, where a shadow is the only thing
    /// separating it from what it covers.
    case floating

    var radius: CGFloat {
        switch self {
        case .resting: return 0
        case .floating: return 12
        }
    }

    var opacity: Double {
        switch self {
        case .resting: return 0
        case .floating: return 0.18
        }
    }

    var offsetY: CGFloat {
        switch self {
        case .resting: return 0
        case .floating: return 4
        }
    }
}

extension View {
    func elevated(_ elevation: Elevation) -> some View {
        shadow(
            color: .black.opacity(elevation.opacity),
            radius: elevation.radius,
            x: 0,
            y: elevation.offsetY
        )
    }

    /// A control that is always at least as big as a fingertip, whatever its content measures.
    func tappable() -> some View {
        frame(minWidth: Metrics.minimumTapTarget, minHeight: Metrics.minimumTapTarget)
            .contentShape(Rectangle())
    }

    /// Keeps a column readable on a wide screen without changing anything on a phone, where the
    /// screen is narrower than the cap and the frame is a no-op.
    func readableColumn() -> some View {
        frame(maxWidth: Metrics.readableColumnWidth)
            .frame(maxWidth: .infinity)
    }

    /// A secondary column beside a primary one: its share of the width the split has, capped.
    /// Proportional below the cap and fixed above it, so no screen needs a breakpoint.
    ///
    /// The width is passed in on purpose. `containerRelativeFrame` is the obvious tool and the
    /// wrong one: inside an `HStack` it measured the column at zero points wide at 626, 1024 and
    /// 1366, and its failure is the panel vanishing.
    func sideColumn(max cap: CGFloat, in available: CGFloat) -> some View {
        frame(width: min(cap, available * 0.45))
    }

    /// Starts this row's list separator at the row's own leading edge.
    ///
    /// A `List` otherwise starts the separator at the first text after an icon: right for a row
    /// that leads with one, wrong for a row that leads with a title and carries `Label`s
    /// underneath, where the line starts under a label 40 pt in. `listRowSeparatorLeading` is the
    /// system's own guide, so the separator keeps the system's colour, thickness and trailing
    /// inset.
    func listSeparatorAtRowLeading() -> some View {
        alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
    }
}

/// The app's one card treatment: Liquid Glass on iOS 26, the flat surface below it. The
/// availability check lives here once, so the two designs cannot drift apart.
struct CardSurface: ViewModifier {
    var radius: CGFloat = Radius.large
    var elevation: Elevation = .resting
    /// Glass reads as glass only over something. A card on a plain background wants the opaque
    /// surface even on iOS 26, or it renders as a faint smudge with unreadable text over it.
    var overContent = false

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *), overContent {
            content
                .glassEffect(.regular, in: .rect(cornerRadius: radius))
                .elevated(elevation)
        } else {
            content
                .background(
                    Color.appSurface,
                    in: RoundedRectangle(cornerRadius: radius, style: .continuous)
                )
                .elevated(elevation)
        }
    }
}

extension View {
    func cardSurface(
        radius: CGFloat = Radius.large,
        elevation: Elevation = .resting,
        overContent: Bool = false
    ) -> some View {
        modifier(CardSurface(radius: radius, elevation: elevation, overContent: overContent))
    }
}
