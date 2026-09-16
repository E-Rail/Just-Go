import SwiftUI

/// The app's type ramp as three roles. `.rowTitle` names a thing; `.rowValue` is the thing, never
/// smaller than its title; `.rowMeta` is genuine metadata (a count, a source, a timestamp) and the
/// only one allowed to be small.
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

/// A metro line's designation drawn the way the network draws it: the number in its line colour,
/// matching the signs riders look for.
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
            // Line branding runs from pale yellow to near-black, so the label colour is measured
            // against the fill (white disappears into Beijing's 13号线 yellow).
            .foregroundStyle(Color.legibleText(onHex: hex))
            .accessibilityHidden(true)
    }

    /// What a rider would call the line: "2" from "2号线" or "长沙地铁二号线", "S1" from "S1线", "荃灣"
    /// from "港鐵荃灣綫". The shortest unambiguous form, not a truncation.
    static func shortLabel(for name: String) -> String {
        // A bracketed qualifier ("(下)") and the system's own name — the operator or mode word and
        // any city before it, which every line in the network shares — say nothing about which line
        // this is.
        let trimmed = name
            .replacingOccurrences(of: "[（(][^）)]*[）)]", with: "", options: .regularExpression)
            .replacingOccurrences(
                of: "^.*?(地铁|地鐵|捷运系统|捷运|捷運|轨道交通|軌道交通|港铁|港鐵|轻轨|輕軌|城际|城際|市郊铁路)\\s*(?=.*[线綫線0-9])",
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespaces)
        let numbered = arabicNumeral(trimmed)
        if let digits = numbered.range(of: "[0-9]+[A-Z]?", options: .regularExpression) {
            // A letter glued to the front of the number is part of the designation ("S1", "M2");
            // one merely nearby is not, which is what separates "S1线" from "Line 2".
            let before = numbered[..<digits.lowerBound]
            let prefix = String(before.reversed().prefix(while: { $0.isLetter && $0.isASCII }).reversed())
            // The preceding character disqualifies a designation only when it is an *ASCII* letter
            // (the tail of a Latin word): `isLetter` is also true for CJK, which would badge
            // 成都市域铁路S3资阳线 as "3" beside 成都地铁3号线.
            let isDesignation = prefix.count <= 2 && !prefix.isEmpty
                && before.dropLast(prefix.count).last.map { !($0.isLetter && $0.isASCII) } ?? true
            return (isDesignation ? prefix.uppercased() : "") + numbered[digits]
        }
        // No number: Latin names reduce to initials, CJK to the name without the "line" (and
        // "express") suffix every such line shares, cut to two characters past three.
        let words = trimmed.split(separator: " ").filter { $0.lowercased() != "line" }
        if words.count > 1, words.allSatisfy({ $0.first?.isASCII == true }) {
            return words.prefix(2).compactMap { $0.first }.map(String.init).joined().uppercased()
        }
        let stripped = trimmed.replacingOccurrences(of: "快?[线綫線]|\\s", with: "", options: .regularExpression)
        let label = stripped.isEmpty ? trimmed : stripped
        return label.count <= 3 ? label : String(label.prefix(2))
    }

    /// "二号线" → "2号线", so a line numbered in Chinese badges like one numbered in digits.
    private static func arabicNumeral(_ name: String) -> String {
        guard let range = name.range(of: "[一二三四五六七八九十]+(?=[号號])", options: .regularExpression) else {
            return name
        }
        let units = Array("一二三四五六七八九")
        var tens = 0
        var unit = 0
        for character in name[range] {
            if character == "十" {
                tens = max(unit, 1)
                unit = 0
            } else {
                unit = (units.firstIndex(of: character) ?? 0) + 1
            }
        }
        return name.replacingCharacters(in: range, with: String(tens * 10 + unit))
    }
}

/// A whole journey as one line of badges (walk, line, line, walk), so routes are told apart by
/// shape. Access legs carry their icon and minutes ("🚶 21" and "🚲 7" are different trips); a ride's
/// badge is its line number. Transfers are left out: two adjacent line badges already say it.
struct JourneyBadgeChain: View {
    let segments: [RouteSegment]
    var size: CGFloat = 26
    /// Scales with the rider's text size, capped at 2×: at the full 3.1× a five-badge chain runs
    /// off a fixed-width card.
    @ScaledMetric(relativeTo: .subheadline) private var typeScale: CGFloat = 1

    private var scaled: CGFloat { size * min(typeScale, 2) }

    var body: some View {
        HStack(spacing: 5) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, segment in
                if index > 0 {
                    Image(systemName: "chevron.compact.right")
                        .font(.system(size: scaled * 0.5, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                if segment.type == .subway {
                    LineBadge(name: segment.lineName ?? "", colorHex: segment.lineColorHex, size: scaled)
                } else {
                    accessBadge(segment)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func accessBadge(_ segment: RouteSegment) -> some View {
        HStack(spacing: scaled * 0.14) {
            Image(systemName: segment.type.symbolName)
                .font(.system(size: scaled * 0.52, weight: .semibold))
            Text("\(Self.minutes(segment.duration))")
                .font(.system(size: scaled * 0.46, weight: .semibold))
                .monospacedDigit()
        }
        .foregroundStyle(Color(hex: segment.colorHex))
        .padding(.horizontal, scaled * 0.26)
        .frame(height: scaled)
        .background(Color(hex: segment.colorHex).opacity(0.16), in: RoundedRectangle(cornerRadius: scaled * 0.3, style: .continuous))
    }

    /// Rounded, and never zero: a 40-second walk is still a leg, and "0" reads as unknown.
    private static func minutes(_ duration: TimeInterval) -> Int {
        max(1, Int((duration / 60).rounded()))
    }

    private var shown: [RouteSegment] { segments.filter { $0.type != .transfer } }
}

/// The continuous vertical line that ties a journey's legs into one path, drawn in the leg's own
/// colour and dash (`SegmentType.colorHex(line:)`, `dash(width:)`) so it matches the maps. One
/// stroked path rather than a stack of capsules, so adjacent legs actually touch.
struct JourneyRail: View {
    let segment: RouteSegment?
    var width: CGFloat = 6

    var body: some View {
        let dash = segment?.type.dash(width: width) ?? []
        RailPath()
            .stroke(
                Color(hex: segment?.colorHex ?? SegmentType.walking.colorHex(line: nil)),
                // Butt caps on a solid rail, so it ends flush against the next leg's.
                style: StrokeStyle(lineWidth: width, lineCap: dash.isEmpty ? .butt : .round, dash: dash)
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

/// The card, in the one treatment from `Core/DesignSystem.swift`
/// (`.cardSurface(radius:elevation:)`), so every card on a screen reads as the same kind of thing.
struct GlassCard<Content: View>: View {
    let content: Content
    /// Set on cards drawn over the map, where glass has something to refract and a shadow is the
    /// only thing separating the card from what it covers.
    var overContent = false

    init(overContent: Bool = false, @ViewBuilder content: () -> Content) {
        self.overContent = overContent
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Metrics.l)
            .cardSurface(
                radius: Radius.large,
                elevation: overContent ? .floating : .resting,
                overContent: overContent
            )
    }
}
