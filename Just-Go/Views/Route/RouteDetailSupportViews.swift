import SwiftUI
import UIKit

extension RouteConfidenceLevel {
    var color: Color {
        switch self {
        case .high: return .green
        case .medium: return .orange
        case .low: return .red
        }
    }
}

/// How a route's confidence reads everywhere it is shown: a dial filled clockwise from twelve
/// o'clock to `score`/100, tinted by level, with the score in the middle. It never sweeps: a moving
/// arc reads as still loading.
struct ConfidenceScoreRing: View {
    let score: Int
    let color: Color
    var size: CGFloat = 48
    var lineWidth: CGFloat = 4

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The score is already clamped to 0-100 by `RouteConfidenceService`, but the ring must not
    /// depend on that: an over-full trim silently wraps past twelve and understates the score.
    private var fraction: Double { min(1, max(0, Double(score) / 100)) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.15), lineWidth: lineWidth)
            Circle()
                // Derived from `score`, not animated in from `@State` on appear: `onAppear` does
                // not fire under `ImageRenderer` or in previews, where the ring would render empty.
                .trim(from: 0, to: fraction)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                // `trim` starts at three o'clock; a dial has to start at twelve.
                .rotationEffect(.degrees(-90))
                .animation(reduceMotion ? nil : .easeOut(duration: 0.35), value: fraction)
            Text("\(score)")
                .font(.system(size: size * 0.34, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AppLocalization.text(
            english: "Confidence \(score) out of 100",
            simplified: "置信度 \(score) 分（满分 100）",
            traditional: "信心度 \(score) 分（滿分 100）"
        ))
    }
}

/// The single worst thing about a route, or nothing when nothing is wrong. Feasibility outranks
/// confidence: "there are stairs" is a fact about the trip, a confidence score a fact about our
/// data. Shared by the results row and the detail hero so a route cannot be flagged on one and
/// clean on the other. A green badge on a route with nothing wrong is decoration.
enum RouteConcern {
    /// - Parameter gradesData: whether this route rides anything the confidence score is about. The
    /// score grades station and network data, which a walk or a drive does not use. Feasibility
    /// still applies: it reads the walking directions, and stairs on a footpath are real.
    static func worst(
        feasibility: RouteFeasibility,
        confidence: RouteConfidence,
        gradesData: Bool = true
    ) -> (title: String, icon: String, tint: Color)? {
        if feasibility.level != .good, feasibility.level != .unknown {
            return (feasibility.title, feasibility.level.iconName, feasibility.level.color)
        }
        guard gradesData, confidence.level != .high else { return nil }
        let icon: String = confidence.level == .medium
            ? "exclamationmark.triangle.fill"
            : "exclamationmark.octagon.fill"
        return (confidence.level.title, icon, confidence.level.color)
    }
}

/// Confidence and feasibility on one screen, one tap from the route.
struct RouteConfidenceDetailView: View {
    let confidence: RouteConfidence
    let feasibility: RouteFeasibility

    var body: some View {
        List {
            Section {
                HStack(spacing: 16) {
                    ConfidenceScoreRing(
                        score: confidence.score,
                        color: confidence.level.color,
                        size: 64,
                        lineWidth: 5
                    )
                    VStack(alignment: .leading, spacing: 3) {
                        Text(confidence.level.title)
                            .font(.headline)
                            .foregroundStyle(confidence.level.color)
                        Text(confidence.level.summary)
                            .rowMeta()
                    }
                }
                .padding(.vertical, 4)
                Text(confidence.explanation)
                    .rowValue()
            }

            if !accessibilityNotes.isEmpty {
                Section {
                    ForEach(accessibilityNotes, id: \.self) { note in
                        Text(note).rowValue()
                    }
                    if feasibility.estimatedExtraMinutes > 0 {
                        LabeledContent {
                            Text(AppLocalization.text(
                                english: "+\(feasibility.estimatedExtraMinutes) min",
                                chinese: "+\(feasibility.estimatedExtraMinutes) 分钟"
                            ))
                            .rowValue()
                        } label: {
                            Text(AppLocalization.text(
                                english: "Possible delay",
                                simplified: "可能增加",
                                traditional: "可能增加"
                            ))
                        }
                    }
                } header: {
                    Label(feasibility.title, systemImage: feasibility.level.iconName)
                        .foregroundStyle(feasibility.level.color)
                }
            }

            if !warnings.isEmpty {
                Section {
                    ForEach(warnings, id: \.self) { warning in
                        Label {
                            Text(warning).rowValue()
                        } icon: {
                            // Explicitly orange: untinted, the triangle inherits the accent.
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                } header: {
                    Text(AppLocalization.text(english: "Watch out for", simplified: "需要注意", traditional: "需要注意"))
                }
            }

            if !confidence.positiveReasons.isEmpty {
                Section {
                    ForEach(confidence.positiveReasons.prefix(5), id: \.self) { reason in
                        Label(reason, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .rowValue()
                    }
                } header: {
                    Text(AppLocalization.text(english: "In your favour", simplified: "有利因素", traditional: "有利因素"))
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.appBackground)
        .navigationTitle(AppLocalization.localized("Trip Confidence"))
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Warnings the screen has not already made, capped at five: `confidence.warnings` repeats the
    /// feasibility verdict that heads its own section.
    private var warnings: [String] {
        confidence.warnings.filter { $0 != feasibility.title }.prefix(5).map { $0 }
    }

    /// The bottleneck first, then the explanations, and nothing when there is nothing to report.
    private var accessibilityNotes: [String] {
        var notes: [String] = []
        if let bottleneck = feasibility.bottleneck {
            notes.append("\(bottleneck.segmentTitle): \(bottleneck.reason)")
        }
        notes.append(contentsOf: feasibility.allExplanations.prefix(4))
        return notes
    }
}

/// How a `DataConfidence` reads visually: fixed semantic colours (official green, estimated or
/// pending orange, unavailable red, unknown grey), not theme-tinted.
extension DataConfidence {
    var color: Color {
        switch self {
        case .official, .communityVerified: return .green
        case .estimated, .mapKit, .sourcePending, .personal: return .orange
        case .unavailable: return .red
        case .unknown: return .gray
        }
    }
}

/// Compact capsule labeling the data source behind a piece of guidance:
/// official (green) / estimated (orange) / not available (red) / no data (gray).
struct DataConfidenceChip: View {
    let confidence: DataConfidence
    var compact = false

    private var icon: String {
        switch confidence {
        case .official, .communityVerified: return "checkmark.seal.fill"
        case .estimated, .mapKit, .sourcePending, .personal: return "exclamationmark.circle.fill"
        case .unavailable: return "xmark.circle.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
            Text(confidence.label)
                .font(.caption2)
                .fontWeight(.medium)
        }
        .padding(.horizontal, compact ? 6 : 8)
        .padding(.vertical, compact ? 2 : 4)
        .background(confidence.color, in: Capsule())
        // Black, not white: these are iOS system green/orange/red/gray, all mid-luminance
        // colors that fail WCAG AA contrast against white text (verified ~2.2-3.6:1) but
        // pass comfortably against black (~5.9-9.6:1), in both light and dark appearance.
        .foregroundStyle(.black)
        .accessibilityElement(children: .combine)
    }
}

/// Reports that the page it sits on is *starting* to leave, which SwiftUI has no signal for.
/// `onDisappear` runs after the page is off screen, too late for anything that must animate with
/// the pop.
///
/// `viewWillDisappear` covers a tapped back button and a swipe alike, with `viewWillAppear` again
/// if the swipe is abandoned. It does not fire for a sheet presented over the page: UIKit sends the
/// presenter no appearance callbacks.
struct PageTransitionObserver: UIViewControllerRepresentable {
    /// The page is starting to leave. Runs for a back button and for a back-swipe alike.
    let onLeaving: () -> Void
    /// It came back: an abandoned swipe, or the page being returned to.
    let onReturned: () -> Void

    func makeUIViewController(context: Context) -> Controller {
        let controller = Controller()
        controller.onLeaving = onLeaving
        controller.onReturned = onReturned
        return controller
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.onLeaving = onLeaving
        controller.onReturned = onReturned
    }

    final class Controller: UIViewController {
        var onLeaving: (() -> Void)?
        var onReturned: (() -> Void)?
        private var hasAppeared = false

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            onLeaving?()
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            // The first call is the page arriving, not returning; reporting it as a return would
            // misname the event.
            guard hasAppeared else {
                hasAppeared = true
                return
            }
            onReturned?()
        }
    }
}
