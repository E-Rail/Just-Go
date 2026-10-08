import ActivityKit
import SwiftUI
import WidgetKit

@main
struct TripLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        TripLiveActivity()
    }
}

/// A trip in progress on the Lock Screen and in the Dynamic Island.
///
/// Draws `TripActivityAttributes.ContentState` and nothing else: every word is the app's, so this
/// target carries no localization and no trip logic. The bar and the countdown run between the
/// step's two dates on the system's clock, which is what keeps the activity moving while the app
/// is asleep underground.
struct TripLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TripActivityAttributes.self) { context in
            TripLockScreenView(
                state: context.state,
                destination: context.attributes.destination,
                isStale: context.isStale
            )
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    TripStepMark(state: state, size: 34)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    TripStepCount(state: state, timerWidth: 68)
                        .font(.title2)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(state.title)
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        if let line = state.stopsText ?? state.detail {
                            Text(line)
                                .font(.subheadline)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        TripStepProgress(state: state)
                        TripBasisLine(state: state, isStale: context.isStale)
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                TripStepMark(state: state, size: 22)
            } compactTrailing: {
                TripStepCount(state: state)
                    .font(.subheadline)
            } minimal: {
                Image(systemName: state.symbolName)
                    .foregroundStyle(Color.adaptive(hex: state.colorHex))
            }
            .keylineTint(Color(hex: state.colorHex))
        }
    }
}
