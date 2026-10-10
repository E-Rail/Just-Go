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
/// target carries no localization and no trip logic. The compact island keeps to a mark and one
/// fact; the picture of the step is for the expanded island and the Lock Screen, which have the
/// room for it.
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
                    TripStepMark(state: state, size: 36)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    TripArrival(state: state)
                        .font(.title3)
                        .padding(.trailing, 4)
                }
                // Nothing in the centre: the gap between the mark and the arrival holds half a
                // headline, and "Get off at the next stop" is the one line that must not be cut.
                DynamicIslandExpandedRegion(.bottom) {
                    TripIslandDetail(state: state, isStale: context.isStale)
                        .padding(.horizontal, 4)
                }
            } compactLeading: {
                TripStepMark(state: state, size: 22)
            } compactTrailing: {
                TripCompactFact(state: state, isStale: context.isStale)
                    .font(.subheadline)
            } minimal: {
                TripStepMark(state: state, size: 20)
            }
            .keylineTint(Color(hex: state.colorHex))
        }
    }
}
