import SwiftUI

/// Transit summary card shown for every route in the results list:
/// a trip-confidence ring, the boarding line badge with trip stats, and a
/// departure → arrival timeline with a dot per transfer.
struct RouteCard: View {
    let route: Route
    let confidence: RouteConfidence
    let departureDate: Date
    let action: () -> Void
    // Parsed once at construction rather than re-parsing the hex on each of the several
    // `lineColor` reads in the per-point timeline on every body evaluation.
    private let lineColor: Color

    init(route: Route, confidence: RouteConfidence, departureDate: Date, action: @escaping () -> Void) {
        self.route = route
        self.confidence = confidence
        self.departureDate = departureDate
        self.action = action
        self.lineColor = Color.adaptive(hex: route.boardingTransitSegment?.lineColorHex ?? "#FF3B30")
    }

    private var arrivalDate: Date {
        departureDate.addingTimeInterval(route.totalDuration)
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 16) {
                confidenceHeader
                boardingBadge
                if let warning = confidence.warnings.first {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(confidence.level.color)
                        .lineLimit(2)
                }
                journeyTimeline
            }
            .padding(16)
            .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 18))
            .shadow(color: .black.opacity(0.05), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    // MARK: - Confidence header

    private var confidenceHeader: some View {
        HStack(spacing: 16) {
            confidenceRing
            VStack(alignment: .leading, spacing: 3) {
                Text(AppLocalization.localized("Trip Confidence"))
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .tracking(0.8)
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                Text(confidence.level.summary)
                    .font(.title3)
                    .fontWeight(.bold)
                    .foregroundStyle(.primary)
                if !confidence.positiveReasons.isEmpty {
                    Text(confidence.positiveReasons.prefix(2).joined(separator: " · "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var confidenceRing: some View {
        ZStack {
            Circle()
                .stroke(Color(.systemGray5), lineWidth: 7)
            Circle()
                .trim(from: 0, to: CGFloat(min(100, max(0, confidence.score))) / 100)
                .stroke(confidence.level.color, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: -1) {
                Text("\(confidence.score)")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundStyle(.primary)
                Text("/100")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 76, height: 76)
    }

    // MARK: - Boarding line badge

    private var boardingBadge: some View {
        HStack(spacing: 12) {
            badgeCircle
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(badgeTitle)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                Text(badgeMeta)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.appSurfaceSecondary, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var badgeCircle: some View {
        if let segment = route.boardingTransitSegment {
            ZStack {
                Circle().fill(Color(hex: segment.lineColorHex ?? "#007AFF"))
                Text(lineShortCode(from: segment.lineName))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        } else {
            ZStack {
                Circle().fill(Color(.systemGray3))
                Image(systemName: "figure.walk")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
    }

    private var badgeTitle: String {
        guard let segment = route.boardingTransitSegment, let lineName = segment.lineName else {
            return AppLocalization.text(english: "Walking route", simplified: "步行路线", traditional: "步行路線")
        }
        let lineDescriptor: String
        if route.transferCount > 0 {
            lineDescriptor = "\(lineName) +\(route.transferCount)"
        } else {
            lineDescriptor = lineName
        }
        return "\(lineDescriptor) · \(AppLocalization.stops(route.totalStops))"
    }

    private var badgeMeta: String {
        var parts = [route.formattedDuration]
        if let fare = route.estimatedFare {
            parts.append(fare.formatted)
        }
        parts.append(AppLocalization.distance(totalDistanceMeters))
        return parts.joined(separator: " · ")
    }

    private var totalDistanceMeters: Double {
        route.segments.reduce(0.0) { $0 + $1.distance }
    }

    private func lineShortCode(from name: String?) -> String {
        guard let name else { return "?" }
        let nums = name.filter(\.isNumber)
        if !nums.isEmpty { return String(nums.prefix(2)) }
        let letters = name.filter { $0.isLetter && $0.isASCII }
        let code = String(letters.prefix(2)).uppercased()
        return code.isEmpty ? "?" : code
    }

    // MARK: - Departure → arrival timeline

    private var journeyTimeline: some View {
        HStack(spacing: 8) {
            Text(Self.clock.string(from: departureDate))
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            timelineTrack

            Text(Self.clock.string(from: arrivalDate))
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private var timelineTrack: some View {
        let pointCount = route.transferCount + 2 // start + transfers + end
        return HStack(spacing: 0) {
            ForEach(0..<pointCount, id: \.self) { index in
                let isEndpoint = index == 0 || index == pointCount - 1
                Circle()
                    .fill(isEndpoint ? lineColor : Color.appSurface)
                    .frame(width: 9, height: 9)
                    .overlay(Circle().stroke(lineColor, lineWidth: isEndpoint ? 0 : 2))
                if index < pointCount - 1 {
                    Rectangle()
                        .fill(lineColor)
                        .frame(height: 3)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private var accessibilitySummary: String {
        [
            "\(confidence.level.title), \(confidence.score) \(AppLocalization.localized("out of 100"))",
            badgeTitle,
            badgeMeta,
        ].joined(separator: ", ")
    }
}

extension RouteConfidenceLevel {
    var color: Color {
        switch self {
        case .high: return .green
        case .medium: return .orange
        case .low: return .red
        }
    }

    var iconName: String {
        switch self {
        case .high: return "checkmark.seal.fill"
        case .medium: return "exclamationmark.triangle.fill"
        case .low: return "xmark.octagon.fill"
        }
    }
}
