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

    /// Width past which a screen should stop being one tall column and start using its width.
    /// Below this, layouts stay exactly as they are on a phone.
    static let regularWidthThreshold: CGFloat = 700

    /// How wide a column of text or cards is allowed to get before it stops being readable. An
    /// iPad in landscape is 1366 points across; a 1366-point-wide list row is not a design, it is
    /// the absence of one.
    /// The trip column beside a map on regular width. Wide enough for a journey row with a line
    /// badge, a station pair and a duration without wrapping, and narrow enough to leave the map
    /// the larger half on every iPad this ships to.
    static let tripColumnWidth: CGFloat = 420

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
