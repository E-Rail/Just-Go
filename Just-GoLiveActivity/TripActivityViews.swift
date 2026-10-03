import SwiftUI

// The views a trip's Live Activity is made of. SwiftUI only: nothing here knows it is drawn on a
// Lock Screen, so the same views serve every region of the Dynamic Island.

struct TripLockScreenView: View {
    let state: TripActivityAttributes.ContentState
    let destination: String
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                TripStepMark(state: state, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.title)
                        .font(.headline)
                        .lineLimit(2)
                    if let detail = state.detail {
                        Text(detail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                TripStepCount(state: state, timerWidth: 84)
                    .font(.title)
            }
            if let stops = state.stopsText {
                // Not in the line's colour: the badge carries that, and a pale line (Beijing's
                // 13号线 yellow) is unreadable as text on a light Lock Screen.
                Text(stops)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            TripStepProgress(state: state)
            HStack(spacing: 8) {
                TripBasisLine(state: state, isStale: isStale)
                Spacer(minLength: 8)
                Label(destination, systemImage: "flag.checkered")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(16)
    }
}

/// The step's mark: a ride's line badge in the line's own colour, or the step's symbol.
struct TripStepMark: View {
    let state: TripActivityAttributes.ContentState
    let size: CGFloat

    var body: some View {
        if let badge = state.badge {
            Text(badge)
                .font(.system(size: size * 0.45, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(.horizontal, size * 0.18)
                .frame(minWidth: size, minHeight: size)
                .background(Color(hex: state.colorHex), in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
                // Line branding runs from pale yellow to near-black, so the label is measured
                // against the fill.
                .foregroundStyle(Color.legibleText(onHex: state.colorHex))
        } else {
            Image(systemName: state.symbolName)
                .font(.system(size: size * 0.6, weight: .semibold))
                .foregroundStyle(Color.adaptive(hex: state.colorHex))
                .frame(minWidth: size, minHeight: size)
        }
    }
}

/// The one number for the step: a ride's stops left, anything else's time left.
struct TripStepCount: View {
    let state: TripActivityAttributes.ContentState
    /// A timer text takes all the width it is offered, so each place it appears says how much
    /// "12:34" needs at its own font.
    var timerWidth: CGFloat = 52

    var body: some View {
        if let stops = state.stopsRemaining {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(verbatim: "\(stops)")
                    .fontWeight(.bold)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                if let unit = state.stopsUnit {
                    Text(unit)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        } else if state.stepEndsAt > Date() {
            Text(timerInterval: Date()...state.stepEndsAt, countsDown: true)
                .fontWeight(.semibold)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: timerWidth)
        }
    }
}

struct TripStepProgress: View {
    let state: TripActivityAttributes.ContentState

    var body: some View {
        // A step with no length (arrival) has nothing to run a bar across.
        if state.stepEndsAt > state.stepStartedAt {
            ProgressView(timerInterval: state.stepStartedAt...state.stepEndsAt, countsDown: false) {
                EmptyView()
            } currentValueLabel: {
                EmptyView()
            }
            .tint(Color.adaptive(hex: state.colorHex))
        }
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
