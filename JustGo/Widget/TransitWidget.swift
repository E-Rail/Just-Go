import WidgetKit
import SwiftUI

struct TransitTimelineEntry: TimelineEntry {
    let date: Date
    let nearestStation: String
    let lineName: String
    let lineColor: String
    let nextArrival: String
    let isAccessible: Bool
}

struct TransitTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> TransitTimelineEntry {
        TransitTimelineEntry(
            date: .now,
            nearestStation: "Beijing Station",
            lineName: "Line 1",
            lineColor: "#C23A30",
            nextArrival: "3 min",
            isAccessible: true
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (TransitTimelineEntry) -> Void) {
        completion(placeholder(in: context))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TransitTimelineEntry>) -> Void) {
        let entry = placeholder(in: context)
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 5, to: .now)!
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }
}

struct TransitWidgetView: View {
    let entry: TransitTimelineEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .systemSmall:
            smallWidget
        case .systemMedium:
            mediumWidget
        case .accessoryRectangular:
            lockScreenWidget
        case .accessoryCircular:
            circularWidget
        default:
            smallWidget
        }
    }

    private var smallWidget: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle()
                    .fill(Color(hex: entry.lineColor))
                    .frame(width: 8, height: 8)
                Text(entry.lineName)
                    .font(.caption)
                    .fontWeight(.medium)
            }

            Text(entry.nearestStation)
                .font(.headline)

            Text(entry.nextArrival)
                .font(.title.bold())

            if entry.isAccessible {
                HStack {
                    Image(systemName: "figure.roll")
                        .font(.caption)
                    Text("Accessible")
                        .font(.caption)
                }
                .foregroundStyle(.green)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var mediumWidget: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Circle()
                        .fill(Color(hex: entry.lineColor))
                        .frame(width: 8, height: 8)
                    Text(entry.lineName)
                        .font(.caption)
                        .fontWeight(.medium)
                }

                Text(entry.nearestStation)
                    .font(.headline)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(entry.nextArrival)
                    .font(.title.bold())

                if entry.isAccessible {
                    HStack {
                        Image(systemName: "figure.roll")
                            .font(.caption)
                        Text("Accessible")
                            .font(.caption)
                    }
                    .foregroundStyle(.green)
                }
            }
        }
    }

    private var lockScreenWidget: some View {
        HStack {
            Image(systemName: "tram.fill")
            Text(entry.nearestStation)
                .font(.headline)
            Spacer()
            Text(entry.nextArrival)
                .bold()
        }
    }

    private var circularWidget: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack {
                Text(entry.nextArrival)
                    .font(.headline)
                Text(entry.lineName)
                    .font(.caption2)
            }
        }
    }
}

struct JustGoWidget: Widget {
    let kind = "JustGoTransit"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TransitTimelineProvider()) { entry in
            TransitWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Transit Status")
        .description("Shows nearby subway station and arrival times")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular])
    }
}
