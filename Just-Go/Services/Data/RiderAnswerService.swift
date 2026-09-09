import Foundation
import Observation

/// What a rider was asked after a trip, and what they said.
///
/// Deliberately a closed set. Every question here is one the app genuinely could not answer for
/// that specific trip — a lift it could not verify, an exit it chose by straight-line distance.
/// Asking about something already in an official feed teaches riders their answers do not matter,
/// so the selection rule lives with the questions and not with the storage.
enum RiderQuestion: String, Codable, Sendable, CaseIterable {
    /// The route claimed step-free access it could not verify at this station.
    case liftToPlatform
    /// The arrival exit was picked by straight-line distance, with nothing to say it was right.
    case exitSide
}

/// Three states, because "I didn't look" is a real answer and forcing it into yes/no would put a
/// claim on the map that nobody made. It is stored and it is never treated as evidence.
enum RiderAnswer: String, Codable, Sendable {
    case yes
    case no
    case didNotLook
}

struct RiderAnswerKey: Codable, Equatable, Hashable, Sendable {
    let cityID: String
    let stationID: String
    let question: RiderQuestion

    var storageID: String { "\(cityID)|\(stationID)|\(question.rawValue)" }
}

/// One answer, kept on the rider's own device, with enough context to be read back.
///
/// `stationName` and `detail` are stored rather than resolved later: the answer is a record of
/// what the rider was looking at when they gave it, and a station renamed or a pack unloaded must
/// not turn their own history into an unreadable ID.
struct RiderAnswerRecord: Codable, Equatable, Sendable {
    let key: RiderAnswerKey
    let answer: RiderAnswer
    let stationName: String
    /// The exit name for `.exitSide`; nil otherwise.
    let detail: String?
    let recordedAt: Date
}

/// Device-local answers, in `UserDefaults`.
///
/// Same shape and the same promises as `TransferInsightService`: nothing derived from sensors, no
/// upload, no account, most recent answer wins, and a hard cap so it grows with trips taken rather
/// than without bound. A rider volunteers the answer or the app does not have it.
///
/// Nothing here is ever presented as official. These are `DataConfidence.personal` and they are
/// used for one thing — the answering rider's own future trips.
@MainActor
@Observable
final class RiderAnswerService {
    private static let storageKey = "riderAnswers.v1"
    private static let maximumAnswers = 500

    private var answers: [String: RiderAnswerRecord]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        answers = defaults.codableValue(forKey: Self.storageKey, as: [String: RiderAnswerRecord].self, default: [:])
    }

    func answer(for key: RiderAnswerKey) -> RiderAnswerRecord? {
        answers[key.storageID]
    }

    /// True when this rider has already been asked this, so the trip never asks twice.
    func hasAnswered(_ key: RiderAnswerKey) -> Bool {
        answers[key.storageID] != nil
    }

    func record(_ answer: RiderAnswer, for key: RiderAnswerKey, stationName: String, detail: String? = nil) {
        answers[key.storageID] = RiderAnswerRecord(
            key: key,
            answer: answer,
            stationName: stationName,
            detail: detail,
            recordedAt: Date()
        )
        if answers.count > Self.maximumAnswers {
            let oldest = answers.values.sorted { $0.recordedAt < $1.recordedAt }
                .prefix(answers.count - Self.maximumAnswers)
            for record in oldest { answers.removeValue(forKey: record.key.storageID) }
        }
        defaults.setCodable(answers, forKey: Self.storageKey)
    }

    /// Everything the rider has answered, newest first.
    var allAnswers: [RiderAnswerRecord] {
        answers.values.sorted { $0.recordedAt > $1.recordedAt }
    }

    func forgetEverything() {
        answers = [:]
        defaults.removeObject(forKey: Self.storageKey)
    }
}
