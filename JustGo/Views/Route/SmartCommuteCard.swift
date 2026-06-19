import SwiftUI

struct SmartCommuteCard: View {
    let trip: SavedTrip
    let isEvening: Bool
    let cityID: String
    let onTap: () -> Void

    @Environment(DIContainer.self) private var container
    @State private var serviceStatus: RouteServiceStatus = .unknown

    private var boardingStationName: String {
        isEvening ? trip.destination.name : trip.origin.name
    }

    private var destinationStationName: String {
        isEvening ? trip.origin.name : trip.destination.name
    }

    private var greeting: String {
        isEvening
            ? AppLocalization.text(english: "Good evening", simplified: "晚上好", traditional: "晚上好")
            : AppLocalization.text(english: "Good morning", simplified: "早上好", traditional: "早上好")
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(greeting)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    Text(boardingStationName)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    Image(systemName: "arrow.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(destinationStationName)
                        .font(.subheadline)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }

                ServiceStatusBanner(status: serviceStatus, compact: true)

                Button(action: onTap) {
                    Text(AppLocalization.text(english: "Use this route", simplified: "使用此路线", traditional: "使用此路線"))
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
            }
        }
        .task(id: boardingStationName) {
            let windows = await container.officialStationData.serviceWindows(cityID: cityID, stationName: boardingStationName)
            serviceStatus = ServiceHoursResolver().status(boardingLineName: nil, windows: windows, at: Date())
        }
    }
}
