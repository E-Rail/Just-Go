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
    /// A **cap**, not a width. Beside a map, `SplitColumns` takes 45% below it, so a narrow
    /// regular-width window still leaves the map the larger part, and where a phone folds the
    /// crease decides instead. Over a map, it is the widest the floating panels get.
    static let tripColumnWidth: CGFloat = 420

    /// The same cap for the stop list beside a line's map. Its own number because a list of station
    /// names needs less room than a journey row with a line badge and a duration.
    static let stopColumnWidth: CGFloat = 380

    /// How wide a column of text or cards may get before it stops being readable. 620 is all but
    /// inert on an iPhone Duo's inner display, 669 points across in portrait, which is fine: 620
    /// points of text is still readable.
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

/// The line between two rows of a card, drawn where a `List` draws it: starting at the row's text
/// rather than at the card's edge, and running all the way to the card's trailing edge — measured
/// against this app's own `List`s on iOS 27, which add no trailing inset of their own.
///
/// A card stacked in a `ScrollView` has no separator to ask for: `listRowSeparatorLeading` is a
/// `List`'s guide and does nothing outside one. So the row's leading column — its mark and the gap
/// after it — is passed in, and the caller states it as the row's own geometry rather than as a
/// number copied from another screen.
struct RowSeparator: View {
    let textInset: CGFloat

    var body: some View {
        Divider().padding(.leading, textInset)
    }
}

/// Where the display folds, in a view's own coordinates, while the fold divides it.
///
/// Read from the system's `.division` reserved region, and only while the system marks it active:
/// on an iPhone Duo the crease is active when the phone is partly folded and inactive when it lies
/// flat and the display is one surface (measured on iOS 27.1). Nil on a display that does not fold.
struct DisplayFold: Equatable {
    /// `.vertical`: the crease runs top to bottom and the panes sit side by side, as in a book.
    /// `.horizontal`: it runs across and the panes stack, as on a laptop.
    let axis: Axis
    /// The crease's centre line, along the axis that crosses it.
    let position: CGFloat
    /// How far interactive content keeps from that line on the leading (or top) side and on the
    /// trailing (or bottom) side: half the crease plus the region's margin.
    let clearanceBefore: CGFloat
    let clearanceAfter: CGFloat

    /// Where the crease's region begins and ends along that same axis; content keeps outside them.
    var start: CGFloat { position - clearanceBefore }
    var end: CGFloat { position + clearanceAfter }
}

/// A view's size and the fold across it, measured together, and the panes the fold makes: the one
/// place the pane arithmetic is written. Holds the size only while folded, so a view measuring this
/// on a display that does not fold sees one unchanging value and is never redrawn for it.
struct FoldedSurface: Equatable {
    private(set) var fold: DisplayFold?
    private var size: CGSize = .zero

    init() {}

    init(_ proxy: GeometryProxy) {
        fold = proxy.activeFold
        size = fold == nil ? .zero : proxy.size
    }

    /// Folded side to side, as a book: one pane before the crease and one beyond it.
    var besideCrease: Bool { fold?.axis == .vertical }

    /// Side to side: how wide the pane before the crease is.
    var paneBeforeWidth: CGFloat? { sideBySide?.start }
    /// Side to side: where the pane beyond the crease begins.
    var paneAfterStart: CGFloat? { sideBySide?.end }
    /// Side to side: how wide the pane beyond the crease is.
    var paneAfterWidth: CGFloat? { sideBySide.map { max(0, size.width - $0.end) } }
    /// Side to side: from the start of the crease's region to the trailing edge, the room a
    /// trailing inset takes so that what it insets keeps to the pane before the crease.
    var beyondCreaseWidth: CGFloat? { sideBySide.map { max(0, size.width - $0.start) } }
    /// Folded across, as a laptop: from the top of the crease's region down, the room a bottom inset
    /// takes so that what it insets keeps to the upper pane.
    var belowCreaseHeight: CGFloat? { stacked.map { max(0, size.height - $0.start) } }
    /// Folded across: how tall the pane below the crease is.
    var paneBelowHeight: CGFloat? { stacked.map { max(0, size.height - $0.end) } }

    private var sideBySide: DisplayFold? { fold?.axis == .vertical ? fold : nil }
    private var stacked: DisplayFold? { fold?.axis == .horizontal ? fold : nil }
}

extension GeometryProxy {
    /// The active fold crossing this view, if any. See `DisplayFold`.
    ///
    /// Gated at compile time as well as at run time: reserved regions exist only in the iOS 27.1
    /// SDK, CI builds with an older one, and an `#available` check alone does not compile there.
    /// The UIKit submodule is that SDK's marker. Without it there is never a fold.
    var activeFold: DisplayFold? {
        #if canImport(UIKit.UIViewReservedRegion)
        if #available(iOS 27.1, *) {
            for region in reservedRegions(kind: .division) where region.isActive {
                let frame = region.frame
                let margins = region.margins
                // The margins surround the crease itself, which may have no width at all.
                if frame.height >= frame.width {
                    let line = (frame.minX + margins.leading + frame.maxX - margins.trailing) / 2
                    guard line > 0, line < size.width else { continue }
                    return DisplayFold(
                        axis: .vertical,
                        position: line,
                        clearanceBefore: line - frame.minX,
                        clearanceAfter: frame.maxX - line
                    )
                } else {
                    let line = (frame.minY + margins.top + frame.maxY - margins.bottom) / 2
                    guard line > 0, line < size.height else { continue }
                    return DisplayFold(
                        axis: .horizontal,
                        position: line,
                        clearanceBefore: line - frame.minY,
                        clearanceAfter: frame.maxY - line
                    )
                }
            }
        }
        #endif
        return nil
    }
}

/// A primary pane and a secondary column. Where the display folds they divide at the crease, one
/// pane to each side; anywhere else the secondary takes its share of the width, capped at
/// `columnCap`, proportional below the cap and fixed above it, so no screen needs a breakpoint.
///
/// One layout whatever the fold does, switched with `AnyLayout`, so both panes keep their identity
/// when a crease becomes active, goes flat or turns with the phone: the map is not rebuilt and the
/// column keeps its scroll position. Each pane stops at the edge of the crease's region and only
/// the divider is drawn inside it. That is padding, not safe-area padding: a map that ignores its
/// safe area, as a full-bleed one does, would otherwise draw its "Legal" link onto the fold.
///
/// The width comes from a `GeometryReader` on purpose. `containerRelativeFrame` is the obvious tool
/// and the wrong one: inside an `HStack` it measured the column at zero points wide at 626, 1024
/// and 1366, and its failure is the panel vanishing.
struct SplitColumns<Primary: View, Secondary: View>: View {
    let columnCap: CGFloat
    @ViewBuilder var primary: Primary
    @ViewBuilder var secondary: Secondary

    var body: some View {
        GeometryReader { geo in
            let surface = FoldedSurface(geo)
            let fold = surface.fold
            let stacked = fold?.axis == .horizontal
            let layout = stacked ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
            layout {
                primary
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(stacked ? .bottom : .trailing, fold?.clearanceBefore ?? 0)
                Divider()
                // Padding adds to the frame it pads, so the pane beyond a crease is its frame plus
                // the clearance, and the two meet on the crease's centre line.
                secondary
                    .frame(
                        width: fold == nil ? min(columnCap, geo.size.width * 0.45) : surface.paneAfterWidth,
                        height: surface.paneBelowHeight
                    )
                    .padding(stacked ? .top : .leading, fold?.clearanceAfter ?? 0)
            }
        }
    }
}

/// Rows stacked edge to edge in a scroll view only as tall as they are, up to `maxHeight`, and
/// scrolling beyond it.
///
/// A plain `ScrollView` takes every point it is offered, and `ViewThatFits` chooses on a proposal
/// its container may already have shrunk: in the rider panel on an iPad it picked the scrolling
/// form for rows that fitted and clipped the nearest station off. The stack is explicit because a
/// scroll view lays loose rows over one another.
struct CappedScroll<Content: View>: View {
    let maxHeight: CGFloat?
    @ViewBuilder var content: Content

    var body: some View {
        CappedHeight(maxHeight: maxHeight) {
            ScrollView {
                VStack(spacing: 0) { content }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

private struct CappedHeight: Layout {
    let maxHeight: CGFloat?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        // Asked for no particular height, a scroll view reports its content's.
        let natural = subview.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: natural.width, height: min(natural.height, maxHeight ?? .infinity))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
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

/// Chrome that floats over a map and is more than one line tall — the rider panel, the guidance
/// panel, the route tabs — in the treatment the system gives its own bars: Liquid Glass, with
/// corners concentric with what holds it. Near a corner of the screen that is the display's own
/// corner, so one panel follows an iPhone's, an iPad's and both of an iPhone Duo's displays with no
/// radius per device; away from every corner it is `minimumRadius`. Below iOS 26, a material.
///
/// No shadow on glass: Liquid Glass draws its own depth. The material and the opaque surface keep
/// `.floating`, which is all that separates them from what they cover.
struct FloatingChrome: ViewModifier {
    var minimumRadius: CGFloat = Radius.large
    /// A wash of colour over the surface: a selected tab's.
    var tint: Color?
    /// The whole surface is one control, so the glass answers a touch the way the system's do.
    var isInteractive = false
    /// The surface below iOS 26, where there is no glass.
    var material: Material = .regularMaterial
    /// Glass reads as glass only over something (see `CardSurface`), so off the map the same shape
    /// is the opaque card surface. The glass is switched to `.identity` rather than removed: one
    /// view tree either way, so a panel that moves off the map keeps its identity.
    var overContent = true
    /// Measured from where the surface sits; nil until then, and where nothing reports a container.
    @State private var concentricRadius: CGFloat?

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            let shape = RoundedRectangle(cornerRadius: concentricRadius ?? minimumRadius, style: .continuous)
            content
                .background(overContent ? Color.clear : Color.appSurface, in: shape)
                .glassEffect(overContent ? .regular.tint(tint).interactive(isInteractive) : .identity, in: shape)
                .elevated(overContent ? .resting : .floating)
                .onGeometryChange(for: CGFloat?.self) { proxy in
                    ConcentricRadius.uniform(in: proxy, minimum: minimumRadius)
                } action: { radius in
                    concentricRadius = radius
                }
        } else {
            // The tint over the material, not instead of it: a selected tab's wash is translucent.
            let shape = RoundedRectangle(cornerRadius: minimumRadius, style: .continuous)
            content
                .background(tint ?? .clear, in: shape)
                .background(overContent ? AnyShapeStyle(material) : AnyShapeStyle(Color.appSurface), in: shape)
                .elevated(.floating)
        }
    }
}

/// The corner radius that makes a surface concentric with what holds it, read from the geometry
/// rather than written down per device.
///
/// Read, not drawn with `ConcentricRectangle`: handed to `glassEffect(in:)` as a parameter that shape
/// has no container to resolve against and draws its minimum at every corner, though the same shape
/// drawn as a view resolves (measured on iOS 27.1). Uniform, every corner taking the largest, so a
/// pill stays a pill; capped at half the short side so it never folds over itself.
///
/// `concentricCornerRadii` is an iOS 27 API and CI builds with an older SDK, so the call is gated at
/// compile time as well as at run time, on the same UIKit submodule `activeFold` uses. That marker
/// first ships in the iOS 27.1 SDK, so a build with any older one keeps the minimum radius.
enum ConcentricRadius {
    static func uniform(in proxy: GeometryProxy, minimum: CGFloat) -> CGFloat? {
        #if canImport(UIKit.UIViewReservedRegion)
        if #available(iOS 27.0, *), let radii = proxy.concentricCornerRadii {
            let largest = max(radii.topLeading, radii.topTrailing, radii.bottomLeading, radii.bottomTrailing)
            return min(max(largest, minimum), min(proxy.size.width, proxy.size.height) / 2)
        }
        #endif
        return nil
    }
}

/// The same treatment in a shape fixed by the control's size: a capsule for anything one line tall
/// (a search field, a notice), a circle for a button. Their radius comes from their height, so they
/// read the same on every device and need no measuring.
struct FloatingChromeShape<S: Shape>: ViewModifier {
    let shape: S
    /// Whether the control is the shape itself, so its glass answers a touch. A notice is not.
    let isInteractive: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(isInteractive), in: shape)
        } else {
            content
                .background(.regularMaterial, in: shape)
                .elevated(.floating)
        }
    }
}

extension View {
    func floatingChrome(
        minimumRadius: CGFloat = Radius.large,
        tint: Color? = nil,
        isInteractive: Bool = false,
        material: Material = .regularMaterial,
        overContent: Bool = true
    ) -> some View {
        modifier(FloatingChrome(
            minimumRadius: minimumRadius,
            tint: tint,
            isInteractive: isInteractive,
            material: material,
            overContent: overContent
        ))
    }

    func floatingChrome<S: Shape>(in shape: S, isInteractive: Bool) -> some View {
        modifier(FloatingChromeShape(shape: shape, isInteractive: isInteractive))
    }

    func cardSurface(
        radius: CGFloat = Radius.large,
        elevation: Elevation = .resting,
        overContent: Bool = false
    ) -> some View {
        modifier(CardSurface(radius: radius, elevation: elevation, overContent: overContent))
    }
}
