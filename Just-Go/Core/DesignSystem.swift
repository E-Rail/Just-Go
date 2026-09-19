import SwiftUI

/// The measurements the app is drawn on.
///
/// There was no such thing before this. `AppTheme` held four accent colours and nothing else, and
/// every spacing, radius and shadow was decided at the call site. The count at the time this was
/// written: **nine distinct corner radii** (3, 4, 5, 6, 8, 10, 12, 14 and 18) and **five ad-hoc
/// shadows**, in a codebase whose own card helper carried a comment claiming a single treatment.
/// Nobody chose nine radii. They accumulated, one reasonable local decision at a time, which is
/// exactly the thing a token set exists to stop.
///
/// Named `Metrics` rather than the more obvious `Layout` because SwiftUI already exports a `Layout`
/// protocol, and the collision resolves silently to theirs at any call site that has not imported
/// this file yet.
enum Metrics {
    /// A four-point rhythm. Everything the app spaces should land on one of these.
    static let hairline: CGFloat = 2
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32

    /// The smallest square a finger can reliably hit. Apple's own floor, and the app had several
    /// controls at 34 and 36.
    static let minimumTapTarget: CGFloat = 44

    /// The trip column beside a map on regular width. Wide enough for a journey row with a line
    /// badge, a station pair and a duration without wrapping, and narrow enough to leave the map
    /// the larger half on every iPad this ships to.
    ///
    /// A **cap**, not a width — apply it through `sideColumn(max:)`. Regular width no longer means
    /// an iPad: a folding phone reports it at 626 points, where a fixed 420 would leave the map 205
    /// and invert the very split this number exists to protect.
    static let tripColumnWidth: CGFloat = 420

    /// The same cap for the stop list beside a line's map. Its own number because a list of station
    /// names needs less room than a journey row with a line badge and a duration.
    static let stopColumnWidth: CGFloat = 380

    /// How wide a column of text or cards is allowed to get before it stops being readable. An
    /// iPad in landscape is 1366 points across; a 1366-point-wide list row is not a design, it is
    /// the absence of one.
    ///
    /// Left at 620 deliberately, even though a folding phone's inner display is 626 points across
    /// and the cap is therefore all but inert there. 620 points of text is still readable, and
    /// retuning a constant against one device's exact width is the thing this number exists to
    /// avoid doing.
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

    /// A secondary column beside a primary one: capped, but never more than its share of the width
    /// the split actually has. Proportional below the cap and fixed above it, so the rule holds at
    /// every width and no screen needs a breakpoint of its own.
    ///
    /// A flat width was safe while regular width meant an iPad, where any of these caps left the
    /// primary side the larger half by construction. A folding phone reports regular width at 626
    /// points, and there the same flat number quietly takes the bigger half instead.
    ///
    /// The width is passed in rather than read from the environment, and that is the whole point.
    /// `containerRelativeFrame` is the obvious tool and is the wrong one: rendered headlessly at
    /// 626, 1024 and 1366, a column sized that way inside an `HStack` came out **zero points wide
    /// at every size** — the greedy primary took all of it. Its failure mode is the panel
    /// vanishing rather than a slightly wrong width, and what counts as its "container" inside a
    /// sheet or a navigation stack is precisely what cannot be checked without the device. An
    /// explicit width has no ambient dependency; the same render measured 282 / 420 / 420.
    func sideColumn(max cap: CGFloat, in available: CGFloat) -> some View {
        frame(width: min(cap, available * 0.45))
    }

    /// Starts this row's list separator at the row's own leading edge.
    ///
    /// Left alone, a `List` starts the separator at the first text that follows an icon, which is
    /// right for a row that *leads* with one — a Settings row, where the line should clear the
    /// glyph — and wrong for a row that leads with a title and carries `Label`s underneath. There
    /// the line started under the first label's text: 56 pt in, below a title at 16 pt, on every
    /// trip in the history. Measured on the iOS 27 simulator, which draws the real separator. An
    /// earlier round reasoned about this instead, fixed one screen, and left the rule wrong here.
    ///
    /// `listRowSeparatorLeading` is the system's own guide for this, so the separator stays the
    /// system's: its colour, its thickness, its trailing inset, and whatever a folding display does
    /// to it. Hiding it and drawing a `Divider` would give all of that up.
    func listSeparatorAtRowLeading() -> some View {
        alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
    }
}

/// The app's one card treatment, in whichever material the OS can draw.
///
/// On iOS 26 this is Liquid Glass, which is what a card floating over a map should have been all
/// along. Below that it is the flat surface the app has always used. Both paths live behind this
/// one modifier so the availability check exists once rather than at ninety call sites, and so the
/// two designs cannot drift apart.
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
