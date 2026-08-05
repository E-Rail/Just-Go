import SwiftUI

/// The app's type ramp, as three names instead of 180 hand-picked `.font()` calls.
///
/// Better than half the text in this app was `.caption` or smaller, and rows routinely drew the
/// *label* larger than the value it introduced — "Exit" at `.subheadline` semibold over the exit's
/// actual name at `.caption` secondary. Naming the three roles makes that inversion impossible to
/// write by accident and makes a later sweep mechanical.
///
/// `.rowTitle` names a thing. `.rowValue` is the thing — never smaller than its title. `.rowMeta`
/// is genuine metadata (a count, a source, a timestamp) and is the only one allowed to be small.
extension View {
    func rowTitle() -> some View {
        font(.subheadline).fontWeight(.medium).foregroundStyle(.secondary)
    }

    func rowValue() -> some View {
        font(.body)
    }

    func rowMeta() -> some View {
        font(.footnote).foregroundStyle(.secondary)
    }
}

/// A metro line's own designation, drawn the way the network draws it: the number in its line
/// colour.
///
/// Line names were previously plain text — "2号线" in the same weight and colour as everything
/// around it. Riders do not navigate by reading line names, they navigate by matching colours and
/// numbers to the signs overhead, so a badge is both the faster read and the one that matches what
/// they are looking at in the station.
struct LineBadge: View {
    let name: String
    let colorHex: String?
    var size: CGFloat = 30

    private var hex: String { colorHex ?? "#8E8E93" }

    var body: some View {
        Text(Self.shortLabel(for: name))
            .font(.system(size: size * 0.45, weight: .heavy, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .padding(.horizontal, size * 0.18)
            .frame(minWidth: size, minHeight: size)
            .background(Color(hex: hex), in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
            // Real line branding runs from pale yellow to near-black, so the label colour has to be
            // measured against the fill rather than fixed — Beijing's 13号线 is a yellow that white
            // text disappears into.
            .foregroundStyle(Color.legibleText(onHex: hex))
            .accessibilityHidden(true)
    }

    /// What a rider would call the line out loud: "2" from "2号线", "13" from "13号线", "S1" from
    /// "S1线", "TW" from "Tsuen Wan Line".
    ///
    /// A badge has room for two or three characters, so the goal is the shortest unambiguous form,
    /// not a truncation — "Tsuen…" identifies nothing.
    static func shortLabel(for name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if let digits = trimmed.range(of: "[0-9]+", options: .regularExpression) {
            // A letter glued to the front of the number is part of the designation ("S1", "M2");
            // one merely nearby is not, which is what separates "S1线" from "Line 2".
            let before = trimmed[..<digits.lowerBound]
            let prefix = before.suffix(while: { $0.isLetter && $0.isASCII })
            // The character before the designation disqualifies it only when it is an *ASCII*
            // letter — i.e. the designation is really the tail of a Latin word. `isLetter` alone
            // is true for CJK, so every Chinese-prefixed line lost its designation: 成都市域铁路S3
            // 资阳线 badged as "3", colliding with 成都地铁3号线 in the same city, and Nanjing
            // rendered S1/S2/S6/S7/S8/S9 as bare numbers against its own 1–9号线.
            let isDesignation = prefix.count <= 2 && !prefix.isEmpty
                && !before.dropLast(prefix.count).last.map { $0.isLetter && $0.isASCII }.orFalse
            return (isDesignation ? prefix.uppercased() : "") + trimmed[digits]
        }
        // No number: Latin names reduce to initials, CJK to the leading characters with the
        // "line" suffix dropped, since every line shares it and it distinguishes nothing.
        let words = trimmed.split(separator: " ").filter { $0.lowercased() != "line" }
        if words.count > 1, words.allSatisfy({ $0.first?.isASCII == true }) {
            return words.prefix(2).compactMap { $0.first }.map(String.init).joined().uppercased()
        }
        let stripped = trimmed.filter { !"线綫線 ".contains($0) }
        return String((stripped.isEmpty ? trimmed : stripped).prefix(2))
    }
}

private extension Optional where Wrapped == Bool {
    var orFalse: Bool { self ?? false }
}

private extension StringProtocol {
    func suffix(while predicate: (Character) -> Bool) -> String {
        String(reversed().prefix(while: predicate).reversed())
    }
}

/// A whole journey compressed to one line of badges — walk, line, line, walk — so two routes can be
/// told apart at a glance by their shape rather than by reading three lines of grey text each.
///
/// Each access leg carries its own icon and its own minutes, because those are the two things that
/// separate otherwise identical-looking routes: "🚶 21" and "🚲 7" describe very different trips
/// and used to render as the same grey walking square. A ride's badge stays the line number — its
/// duration is implied by the stops, and a number beside a line number reads as a second line.
///
/// Transfer legs are left out on purpose: two adjacent line badges already say a transfer happens,
/// and drawing it a third time crowded the chain past the width of a phone.
struct JourneyBadgeChain: View {
    let segments: [RouteSegment]
    var size: CGFloat = 26

    var body: some View {
        HStack(spacing: 5) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, segment in
                if index > 0 {
                    Image(systemName: "chevron.compact.right")
                        .font(.system(size: size * 0.5, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                if segment.type == .subway {
                    LineBadge(name: segment.lineName ?? "", colorHex: segment.lineColorHex, size: size)
                } else {
                    accessBadge(segment)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func accessBadge(_ segment: RouteSegment) -> some View {
        HStack(spacing: size * 0.14) {
            Image(systemName: segment.type.symbolName)
                .font(.system(size: size * 0.52, weight: .semibold))
            Text("\(Self.minutes(segment.duration))")
                .font(.system(size: size * 0.46, weight: .semibold))
                .monospacedDigit()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, size * 0.26)
        .frame(height: size)
        .background(Color.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
    }

    /// Rounded, and never zero: a 40-second walk is still a leg of the trip, and a badge reading
    /// "0" says the app could not work it out rather than "this is quick".
    private static func minutes(_ duration: TimeInterval) -> Int {
        max(1, Int((duration / 60).rounded()))
    }

    private var shown: [RouteSegment] { segments.filter { $0.type != .transfer } }
}

/// The continuous vertical line that ties a journey's legs into one path.
///
/// Solid in the leg's own colour while riding, dashed while on foot — the convention every printed
/// transit map and every well-regarded transit app already uses, so it needs no legend. Drawn as a
/// single stroked path rather than a stack of capsules so that adjacent legs actually touch: the
/// spine has to be unbroken or the trip reads as a list of unrelated errands.
struct JourneyRail: View {
    let color: Color
    var dashed = false
    var width: CGFloat = 6

    var body: some View {
        RailPath()
            .stroke(
                color,
                style: StrokeStyle(
                    lineWidth: width,
                    lineCap: dashed ? .round : .butt,
                    dash: dashed ? [0.1, width * 1.15] : []
                )
            )
            .frame(width: width)
            .accessibilityHidden(true)
    }

    private struct RailPath: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            return path
        }
    }
}

/// The one card treatment in the app.
///
/// Cards were previously drawn five different ways depending on which file you were in —
/// `systemGray6` at radius 10, `.ultraThinMaterial` at 14, `.regularMaterial` at 10, `appSurface` at
/// 12, `GlassCard` at 18 — often two of them stacked on one screen. No single one of those looks
/// wrong; seeing three at once is what makes a screen look assembled rather than designed, because
/// the eye reads differing radii as a differing *kind* of thing and goes looking for the meaning.
extension View {
    func cardSurface(_ cornerRadius: CGFloat = 18) -> some View {
        background(Color.appSurface, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

struct GlassCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .cardSurface()
    }
}
