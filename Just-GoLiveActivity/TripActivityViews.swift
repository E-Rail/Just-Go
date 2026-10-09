import SwiftUI

// The views a trip's Live Activity is made of. SwiftUI only: nothing here knows it is drawn on a
// Lock Screen, so the same views serve every region of the Dynamic Island.
//
// Text and shapes drawn from the state alone. Nothing runs on the system's clock: a view that
// moved by itself would go on moving after the app had stopped knowing where the rider is.

struct TripLockScreenView: View {
    let state: TripActivityAttributes.ContentState
    let destination: String
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                TripStepMark(state: state, size: 40)
                TripStepLines(state: state, isStale: isStale)
                Spacer(minLength: 8)
                TripArrival(state: state)
                    .font(.title2)
            }
            if let leg = state.leg {
                TripLegStrip(state: state, leg: leg, isStale: isStale)
            }
            HStack(spacing: 8) {
                TripBasisLine(state: state, isStale: isStale)
                Spacer(minLength: 8)
                // Only while the strip ends short of it: the trip's last leg and the arrival
                // already name the destination.
                if state.leg?.endColorHex != nil {
                    Label(destination, systemImage: TripLegStrip.destinationSymbolName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(16)
    }
}

/// The expanded island under its mark and its arrival: the headline at the island's full width,
/// the sub line with the basis beside it, and the strip.
struct TripIslandDetail: View {
    let state: TripActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                TripHeadline(state: state, isStale: isStale)
                    .minimumScaleFactor(0.8)
                HStack(spacing: 8) {
                    TripSubLine(state: state, isStale: isStale)
                    Spacer(minLength: 0)
                    TripBasisLine(state: state, isStale: isStale)
                        .fixedSize()
                }
            }
            if let leg = state.leg {
                TripLegStrip(state: state, leg: leg, isStale: isStale)
            }
        }
        // The region centres what does not fill it, and an arrived trip has no strip to fill it.
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A line's badge, as the app draws it everywhere a line is named.
struct TripLineBadge: View {
    let label: String
    let colorHex: String
    let size: CGFloat

    var body: some View {
        Text(label)
            .font(.system(size: size * 0.45, weight: .heavy, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .padding(.horizontal, size * 0.18)
            .frame(minWidth: size, minHeight: size)
            .background(Color(hex: colorHex), in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
            // Line branding runs from pale yellow to near-black, so the label is measured
            // against the fill.
            .foregroundStyle(Color.legibleText(onHex: colorHex))
    }
}

/// The step's mark: a ride's line badge in the line's own colour, or the step's symbol on a plate
/// of the same shape, so the two read as one family.
struct TripStepMark: View {
    let state: TripActivityAttributes.ContentState
    let size: CGFloat

    var body: some View {
        if let badge = state.badge {
            TripLineBadge(label: badge, colorHex: state.colorHex, size: size)
        } else {
            Image(systemName: state.symbolName)
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(Color.adaptive(hex: state.colorHex))
                .frame(width: size, height: size)
                .background(
                    Color(hex: state.colorHex).opacity(0.2),
                    in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                )
        }
    }
}

/// The step in one line. On a ride that is how far there is to go, "2 stops left", which is what
/// a rider looks for; the line itself is already on the badge.
struct TripHeadline: View {
    let state: TripActivityAttributes.ContentState
    let isStale: Bool
    var font = Font.headline
    var lines = 1

    var body: some View {
        // A stale activity no longer knows the stop count. The step's name is still true.
        Text(isStale ? state.title : state.stopsText ?? state.title)
            .font(font)
            .lineLimit(lines)
    }
}

/// Under the headline: the next stop on a ride, otherwise the step in the plan's words.
struct TripSubLine: View {
    let state: TripActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        // A stale activity no longer knows the next stop. The plan's words are still true.
        if let line = isStale ? state.detail : state.nextStopText ?? state.detail {
            Text(line)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}

/// The headline over the sub line, where there is room for a long headline to give way.
///
/// At its own size if it fits on one line, then a size smaller, and failing that on two lines
/// in the sub line's place: a headline cut short loses the name of the door or the station. The
/// sub line is given no width of its own to ask for, so only the headline decides.
struct TripStepLines: View {
    let state: TripActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        ViewThatFits(in: .horizontal) {
            lines(headline: .headline)
            lines(headline: .subheadline.weight(.semibold))
            TripHeadline(state: state, isStale: isStale, lines: 2)
                .minimumScaleFactor(0.8)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func lines(headline: Font) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            TripHeadline(state: state, isStale: isStale, font: headline)
            TripSubLine(state: state, isStale: isStale)
                .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// When the trip is expected to end, as a clock reads, over the words that call it an estimate.
/// The caller sets the time's font.
struct TripArrival: View {
    let state: TripActivityAttributes.ContentState

    var body: some View {
        if let time = state.arrivalText {
            VStack(alignment: .trailing, spacing: 0) {
                Text(time)
                    .fontWeight(.semibold)
                    .fontDesign(.rounded)
                    .monospacedDigit()
                Text(state.arrivalCaption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .fixedSize()
            .accessibilityElement(children: .combine)
        }
    }
}

/// A ride's stops still ahead, as a number and its unit.
struct TripStepCount: View {
    let stops: Int
    let unit: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(verbatim: "\(stops)")
                .fontWeight(.bold)
                .fontDesign(.rounded)
                .monospacedDigit()
                .contentTransition(.numericText())
            if let unit {
                Text(unit)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The one fact the compact island has room for beside the mark: a ride's stops left, the line a
/// walk or a change leads to, or, on the last leg, when the trip ends.
struct TripCompactFact: View {
    let state: TripActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        if let stops = state.stopsRemaining {
            if isStale {
                Image(systemName: "arrow.clockwise")
                    .foregroundStyle(.secondary)
            } else {
                TripStepCount(stops: stops, unit: state.stopsUnit)
            }
        } else if let badge = state.leg?.onwardBadge, let colorHex = state.leg?.onwardColorHex {
            TripLineBadge(label: badge, colorHex: colorHex, size: 22)
        } else if let time = state.arrivalText {
            Text(time)
                .fontWeight(.semibold)
                .fontDesign(.rounded)
                .monospacedDigit()
        }
    }
}

/// The step as a picture, left to right: where it starts, the track with the rider on it, the
/// station it ends at, and the line that leaves from there.
struct TripLegStrip: View {
    let state: TripActivityAttributes.ContentState
    let leg: TripActivityAttributes.Leg
    let isStale: Bool
    /// The track's stroke. Every other size on the strip is a multiple of it, so the strip keeps
    /// its proportions at any width.
    var width: CGFloat = 4

    static let destinationSymbolName = "flag.checkered"

    var body: some View {
        HStack(spacing: width * 1.5) {
            TripTrack(
                colorHex: state.colorHex,
                symbolName: state.symbolName,
                leg: leg,
                isStale: isStale,
                width: width
            )
            if let name = leg.endName {
                Text(name)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .lineLimit(1)
            }
            onward
        }
        // The headline, the sub line and the arrival say all of it in words.
        .accessibilityHidden(true)
    }

    /// The next line's badge, and its colour running on from the station and out of the picture.
    @ViewBuilder private var onward: some View {
        if let badge = leg.onwardBadge, let colorHex = leg.onwardColorHex {
            let color = Color.adaptiveShape(hex: colorHex)
            HStack(spacing: 0) {
                TripLineBadge(label: badge, colorHex: colorHex, size: width * 5)
                Rectangle()
                    .fill(LinearGradient(colors: [color, color.opacity(0)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: width * 7, height: width)
            }
        }
    }
}

/// A leg from its start to its end: a dot where it starts, the rail, and a ring where it ends,
/// with the step's glyph on a disc where the rider is. Full colour ahead of the rider and faint
/// behind, as a map draws a route being followed: what is left is what the rider reads.
///
/// The rail runs from the centre of one end to the centre of the other, so a ride's first stop is
/// the start dot, its last is the ring, and every hop between is the same length.
struct TripTrack: View {
    let colorHex: String
    let symbolName: String
    let leg: TripActivityAttributes.Leg
    let isStale: Bool
    let width: CGFloat

    private var discSize: CGFloat { width * 4.5 }
    private var startSize: CGFloat { width * 2.5 }
    private var endSize: CGFloat { width * 3.5 }
    private static let faint = 0.35

    var body: some View {
        GeometryReader { proxy in
            let middle = proxy.size.height / 2
            let first = startSize / 2
            let last = proxy.size.width - endSize / 2
            let reached = first + (last - first) * fraction
            let rail = TripRail(
                width: width,
                dash: leg.dash.map { CGFloat($0) * width },
                from: first,
                // Up to the ring and not into it; short of the flag, which is not a station.
                to: proxy.size.width - endSize - (leg.endColorHex == nil ? width : 0),
                stops: stops(from: first, to: last)
            )
            let color = Color.adaptiveShape(hex: colorHex)
            ZStack {
                rail.fill(color.opacity(Self.faint))
                // A stale activity does not know where the rider is, and draws the track alone.
                if !isStale {
                    rail.fill(color)
                        .mask(alignment: .trailing) { Rectangle().frame(width: proxy.size.width - reached) }
                }
                start.position(x: first, y: middle)
                end.position(x: last, y: middle)
                if !isStale {
                    Image(systemName: symbolName)
                        .font(.system(size: discSize * 0.55, weight: .semibold))
                        .foregroundStyle(Color.legibleText(onHex: colorHex))
                        .frame(width: discSize, height: discSize)
                        .background(Color(hex: colorHex), in: Circle())
                        .position(x: reached, y: middle)
                }
            }
        }
        .frame(height: discSize)
        .frame(minWidth: discSize * 4)
    }

    /// A dot in the colour of the line just left, faint like the rail once the rider is past it.
    /// Where the leg starts from where the rider set out, the dot a map draws for them.
    @ViewBuilder private var start: some View {
        if let colorHex = leg.startColorHex {
            Circle()
                .fill(Color.adaptiveShape(hex: colorHex).opacity(isStale || fraction > 0 ? Self.faint : 1))
                .frame(width: startSize, height: startSize)
        } else {
            Circle()
                .fill(.blue)
                .strokeBorder(.white, lineWidth: width / 2)
                .frame(width: startSize + width, height: startSize + width)
        }
    }

    /// A ring in the colour of the line the station is on, or the flag at the end of the trip.
    @ViewBuilder private var end: some View {
        if let colorHex = leg.endColorHex {
            Circle()
                .strokeBorder(Color.adaptiveShape(hex: colorHex), lineWidth: width * 0.75)
                .frame(width: endSize, height: endSize)
        } else {
            Image(systemName: TripLegStrip.destinationSymbolName)
                .font(.system(size: endSize * 0.9, weight: .semibold))
                .foregroundStyle(.green)
        }
    }

    private var fraction: CGFloat {
        guard leg.parts > 0 else { return 0 }
        return CGFloat(min(max(leg.place / Double(leg.parts), 0), 1))
    }

    /// Where the stops between a ride's two ends fall, or none when they would stand closer than
    /// the disc and a dot side by side: a twenty-stop ride on a strip this long is a blur of dots.
    private func stops(from first: CGFloat, to last: CGFloat) -> [CGFloat] {
        guard leg.marksStops, leg.parts > 1 else { return [] }
        let hop = (last - first) / CGFloat(leg.parts)
        guard hop >= discSize + TripRail.stopSize(width: width) else { return [] }
        return (1..<leg.parts).map { first + CGFloat($0) * hop }
    }
}

/// A rail as one filled outline: a dashed line, or a solid one with a dot at each stop.
///
/// Pieces that touch and never overlap. Drawn faint, an overlap would show as a darker patch,
/// and filled as one path it could cancel out and show as a hole.
private struct TripRail: Shape {
    let width: CGFloat
    /// In points; empty is solid.
    let dash: [CGFloat]
    /// Where the rail runs, and where each stop on it is marked, in order.
    let from: CGFloat
    let to: CGFloat
    let stops: [CGFloat]

    static func stopSize(width: CGFloat) -> CGFloat { width * 2 }

    func path(in rect: CGRect) -> Path {
        guard to > from else { return Path() }
        guard dash.isEmpty else {
            var line = Path()
            line.move(to: CGPoint(x: rect.minX + from, y: rect.midY))
            line.addLine(to: CGPoint(x: rect.minX + to, y: rect.midY))
            // The default butt cap, which is what the dash is written for.
            return line.strokedPath(StrokeStyle(lineWidth: width, dash: dash))
        }
        let stopSize = Self.stopSize(width: width)
        var path = Path()
        var start = rect.minX + from
        for stop in stops {
            let dot = CGRect(
                x: rect.minX + stop - stopSize / 2,
                y: rect.midY - stopSize / 2,
                width: stopSize,
                height: stopSize
            )
            path.addRect(CGRect(x: start, y: rect.midY - width / 2, width: max(0, dot.minX - start), height: width))
            path.addEllipse(in: dot)
            start = dot.maxX
        }
        path.addRect(CGRect(x: start, y: rect.midY - width / 2, width: max(0, rect.minX + to - start), height: width))
        return path
    }
}

/// How the position is known, or that it no longer is.
struct TripBasisLine: View {
    let state: TripActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        if isStale {
            Label(state.staleText, systemImage: "arrow.clockwise")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else if let basis = state.basisText {
            Label(basis, systemImage: state.isEstimated ? "clock" : "location.fill")
                .font(.caption)
                .foregroundStyle(state.isEstimated ? Color.orange : Color.green)
                .lineLimit(1)
        }
    }
}
