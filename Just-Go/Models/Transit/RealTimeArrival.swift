import Foundation

struct RealtimeArrivalName: Hashable, Sendable {
    let english: String
    let simplifiedChinese: String?
    let traditionalChinese: String?

    init(
        english: String,
        simplifiedChinese: String? = nil,
        traditionalChinese: String? = nil
    ) {
        self.english = english
        self.simplifiedChinese = simplifiedChinese
        self.traditionalChinese = traditionalChinese
    }

    var localized: String {
        let english = nonEmpty(self.english)
        let simplified = simplifiedChinese.flatMap(nonEmpty)
        let traditional = traditionalChinese.flatMap(nonEmpty)

        guard AppLocalization.isChinese else {
            return english ?? traditional ?? simplified ?? ""
        }
        if AppLocalization.isTraditionalChinese {
            return traditional ?? simplified.map(AppLocalization.chinese) ?? english ?? ""
        }
        return simplified
            ?? traditional?.applyingTransform(StringTransform("Hant-Hans"), reverse: false)
            ?? traditional
            ?? english
            ?? ""
    }

    private func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum RealtimeArrivalReference: Hashable, Sendable {
    case hongKongHeavyRail(lineCode: String, stationCode: String)
    case hongKongLightRail(stationID: String)
}

struct RealtimeArrivalRequest: Sendable {
    let stationID: String
    let reference: RealtimeArrivalReference
    let destinationNamesByCode: [String: RealtimeArrivalName]
    let lineName: RealtimeArrivalName
    let lineColorHex: String

    init(
        stationID: String,
        reference: RealtimeArrivalReference,
        destinationNamesByCode: [String: RealtimeArrivalName] = [:],
        lineName: RealtimeArrivalName,
        lineColorHex: String
    ) {
        self.stationID = stationID
        self.reference = reference
        self.destinationNamesByCode = destinationNamesByCode
        self.lineName = lineName
        self.lineColorHex = lineColorHex
    }
}

protocol RealtimeArrivalProviding: Sendable {
    func arrivals(for request: RealtimeArrivalRequest) async throws -> [RealTimeArrival]
}

enum RealtimeArrivalAvailability: Sendable, Equatable {
    case notConfigured
    case available
    case noUpcomingService
    case temporarilyUnavailable
}

struct StationArrivalSnapshot: Sendable, Equatable {
    let arrivals: [RealTimeArrival]
    let realtimeAvailability: RealtimeArrivalAvailability

    static let unavailable = StationArrivalSnapshot(
        arrivals: [],
        realtimeAvailability: .notConfigured
    )
}

enum TrainTimeSource: String, Codable, Sendable {
    case liveCountdown
    case officialSchedule
    case bundledSchedule

    var statusLabel: String {
        switch self {
        case .liveCountdown:
            return AppLocalization.text(
                english: "Live arrival",
                simplified: "实时到站",
                traditional: "即時到站"
            )
        case .officialSchedule:
            return AppLocalization.localized("Official scheduled time")
        case .bundledSchedule:
            return AppLocalization.localized("Bundled schedule")
        }
    }
}

struct RealTimeArrival: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    let lineName: String
    let lineColorHex: String
    let destination: String
    let minutesRemaining: Int?
    let timeText: String?
    let source: TrainTimeSource

    var formattedArrival: String {
        if let minutesRemaining {
            if minutesRemaining <= 0 { return AppLocalization.localized("Arriving") }
            return AppLocalization.minutes(minutesRemaining)
        }
        return timeText ?? AppLocalization.localized("Schedule unavailable")
    }

    var isArriving: Bool {
        minutesRemaining.map { $0 <= 1 } ?? false
    }

    var statusLabel: String {
        source.statusLabel
    }

    var isLiveArrival: Bool {
        source == .liveCountdown
    }

}
