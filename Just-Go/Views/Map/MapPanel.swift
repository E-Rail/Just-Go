import SwiftUI

/// How far a phone's panel rises over the map. The app's own cases rather than
/// `PresentationDetent`s, which cannot be read back: the map needs each one's height to keep what it
/// shows above the panel.
enum PanelStop: Hashable {
    /// The map, with a strip of the page: a trip's summary.
    case low
    case medium
    case large
    /// As tall as the page measured itself: the step of a trip under way.
    case fitted(CGFloat)

    var detent: PresentationDetent {
        switch self {
        case .low: return .fraction(0.3)
        case .medium: return .medium
        case .large: return .large
        case .fitted(let height): return .height(height)
        }
    }

    /// About how much of a screen this tall the panel covers. Nominal: a sheet's fractions are of
    /// the tallest it gets, a little short of the screen. Good enough for the map to keep what it
    /// frames above the panel, which is all this is for.
    func coveredHeight(in height: CGFloat) -> CGFloat {
        switch self {
        case .low: return height * 0.3
        case .medium: return height * 0.5
        case .large: return height
        case .fitted(let fitted): return min(fitted, height)
        }
    }
}

/// The stops a page's panel offers on a phone, and the one it opens at.
struct PanelStops {
    let stops: [PanelStop]
    let opening: PanelStop

    var detents: Set<PresentationDetent> { Set(stops.map(\.detent)) }

    /// Typing pages take the whole height for the keyboard. A page about somewhere opens halfway, so
    /// the map shows where it is; a route opens there too and can drop low to show more of the trip.
    /// A trip under way is exactly as tall as its step, and a change of lines, which the rider reads
    /// standing still, takes the height.
    ///
    /// - Parameters:
    ///   - placeOpening: Where a place card opens, which depends on how the place was found.
    ///   - guidanceHeight: How tall the guidance page measured itself, once it has.
    ///   - isTransferStep: Whether the trip under way is at a change of lines.
    static func forPage(
        _ page: MapRoute,
        placeOpening: PanelStop?,
        guidanceHeight: CGFloat?,
        isTransferStep: Bool
    ) -> PanelStops {
        switch page {
        case .search, .editEndpoint, .transfer, .routeStop, .confidence:
            return PanelStops(stops: [.large], opening: .large)
        case .results, .station, .line:
            return PanelStops(stops: [.medium, .large], opening: .medium)
        case .detail:
            return PanelStops(stops: [.low, .medium, .large], opening: .medium)
        case .place:
            // A dropped pin is a name and a coordinate, and the rider is pointing at the map.
            let opening = placeOpening ?? .medium
            return PanelStops(stops: opening == .low ? [.low, .medium, .large] : [.medium, .large], opening: opening)
        case .guidance:
            guard !isTransferStep, let guidanceHeight else {
                return PanelStops(stops: [.large], opening: .large)
            }
            return PanelStops(stops: [.fitted(guidanceHeight), .large], opening: .fitted(guidanceHeight))
        }
    }
}

/// Where the panel sits on a regular-width screen, and what of the map it covers: the one place its
/// frame is decided. In the shell's safe-area frame, which is where the fold is measured too.
///
/// Folded side to side, the panel is the pane before the crease. Folded across, it is the pane
/// below it, the full width. Otherwise it is a column at the leading edge, up to
/// `Metrics.tripColumnWidth` and never more than 45% of the width, so a narrow regular-width window
/// still leaves the map the larger part.
struct MapPanelLayout {
    let size: CGSize
    let surface: FoldedSurface

    /// The gap between the panel and the screen's edges.
    static let margin = Metrics.m

    var cardLeading: CGFloat { Self.margin }

    var cardTop: CGFloat {
        guard let below = surface.paneBelowHeight else { return Self.margin }
        return size.height - below
    }

    var cardWidth: CGFloat {
        if surface.fold?.axis == .horizontal { return max(0, size.width - 2 * Self.margin) }
        return max(0, columnEnd - Self.margin)
    }

    /// The tallest the card gets: its pane, or the screen, less a margin at each end.
    var maxCardHeight: CGFloat {
        if let below = surface.paneBelowHeight { return max(0, below - Self.margin) }
        return max(0, size.height - 2 * Self.margin)
    }

    /// Where the column ends. Beside a crease, the crease's region begins there.
    private var columnEnd: CGFloat {
        surface.paneBeforeWidth
            ?? min(Metrics.tripColumnWidth + Self.margin, size.width * 0.45)
    }

    /// How much of the map's leading edge the panel takes, so MapKit centres beside it.
    var mapLeadingChrome: CGFloat {
        if surface.fold?.axis == .horizontal { return 0 }
        return surface.paneAfterStart ?? columnEnd + Self.margin
    }

    /// Folded across, everything from the crease down, so the map centres in the upper pane.
    var mapBottomChrome: CGFloat { surface.belowCreaseHeight ?? 0 }

    /// The map's own buttons start after the panel, or above it when it lies across the bottom.
    var controlsLeading: CGFloat {
        if surface.fold?.axis == .horizontal { return 0 }
        return surface.paneAfterStart ?? columnEnd
    }
}

/// Closes the panel from its first page, in the system's own close control where there is one.
struct PanelCloseButton: View {
    let action: () -> Void

    var body: some View {
        if #available(iOS 26.0, *) {
            Button(role: .close, action: action)
        } else {
            Button(action: action) {
                Image(systemName: "xmark")
            }
            .accessibilityLabel(AppLocalization.text(english: "Close", simplified: "关闭", traditional: "關閉"))
        }
    }
}
