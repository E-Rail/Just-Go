import ActivityKit
import SwiftUI
import WidgetKit

struct TransitActivityLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TransitActivityAttributes.self) { context in
            LockScreenLiveActivityView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack {
                        Circle()
                            .fill(Color(hex: context.state.lineColor))
                            .frame(width: 12, height: 12)
                        Text(context.state.lineName)
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                }

                DynamicIslandExpandedRegion(.trailing) {
                    VStack {
                        Text("\(context.state.stopsRemaining)")
                            .font(.title2.bold())
                        Text("stops")
                            .font(.caption)
                    }
                }

                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text(context.state.currentStation)
                            .font(.caption)
                        Spacer()
                        Image(systemName: "arrow.right")
                            .font(.caption)
                        Spacer()
                        Text(context.state.nextStation)
                            .font(.caption)
                    }
                }
            } compactLeading: {
                Circle()
                    .fill(Color(hex: context.state.lineColor))
                    .frame(width: 8, height: 8)
            } compactTrailing: {
                Text("\(context.state.stopsRemaining)")
                    .font(.caption2.bold())
            } minimal: {
                Image(systemName: "tram.fill")
                    .font(.caption2)
            }
        }
    }
}

struct LockScreenLiveActivityView: View {
    let context: ActivityContext<TransitActivityAttributes>

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Circle()
                        .fill(Color(hex: context.state.lineColor))
                        .frame(width: 8, height: 8)
                    Text(context.state.lineName)
                        .font(.caption)
                        .fontWeight(.medium)
                }

                Text(context.state.currentStation)
                    .font(.headline)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                if context.state.status == .arriving {
                    Text("Arriving")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundStyle(.green)
                } else {
                    Text("\(context.state.arrivingIn) min")
                        .font(.title3.bold())
                }

                Text("\(context.state.stopsRemaining) stops left")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }
}
