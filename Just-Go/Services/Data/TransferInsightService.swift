import Foundation
import Observation

/// Where a transfer answer came from, which decides what the app is allowed to call it.
///
/// This exists so honesty is structural rather than a habit. Right now the only answers in
/// existence are the rider's own, and a screen saying "riders say 2–5 min" over a sample of one —
/// them — would be a lie told by the copy rather than by the data. The UI switches on this, so
/// when a shared answer set does arrive nothing has to be remembered.
enum TransferInsightSource: Equatable, Sendable {
    /// Answered by this rider, on this device. The only case produced today.
    case you
    /// Pooled from other riders. Nothing produces this yet — see `RemoteTransferInsightSource`.
    case riders(count: Int)
}

struct TransferInsight: Equatable, Sendable {
    let pace: TransferPace
    let source: TransferInsightSource
}

/// The seam a shared answer set arrives through.
///
/// Deliberately one small protocol with two methods, because the interesting part of this feature
/// is not the storage — it is that the app never derives this from sensors. A rider volunteers the
/// answer or the app does not have it.
protocol TransferInsightStoring: Sendable {
    func insight(for key: TransferKey) -> TransferInsight?
    func record(_ pace: TransferPace, for key: TransferKey)
}

/// Device-local answers, in `UserDefaults`.
///
/// Small and bounded by construction: one entry per line-pair the rider has actually changed at,
/// so it grows with trips taken rather than with the size of the network. The most recent answer
/// wins — a rebuilt interchange should not be outvoted by how it used to be.
@MainActor
@Observable
final class TransferInsightService: TransferInsightStoring {
    private static let storageKey = "transferNotes.v1"
    /// Enough for years of ordinary use; trimmed oldest-first so the cap can never surprise anyone.
    private static let maximumNotes = 500

    private var notes: [String: TransferNote]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        notes = defaults.codableValue(forKey: Self.storageKey, as: [String: TransferNote].self, default: [:])
    }

    nonisolated func insight(for key: TransferKey) -> TransferInsight? {
        MainActor.assumeIsolated {
            guard let note = notes[key.storageID] else { return nil }
            return TransferInsight(pace: note.pace, source: .you)
        }
    }

    nonisolated func record(_ pace: TransferPace, for key: TransferKey) {
        MainActor.assumeIsolated {
            notes[key.storageID] = TransferNote(key: key, pace: pace, recordedAt: Date())
            if notes.count > Self.maximumNotes {
                let oldest = notes.values.sorted { $0.recordedAt < $1.recordedAt }
                    .prefix(notes.count - Self.maximumNotes)
                for note in oldest { notes.removeValue(forKey: note.key.storageID) }
            }
            defaults.setCodable(notes, forKey: Self.storageKey)
        }
    }

    /// Everything the rider has answered, newest first. Feeds a future "things you've told us"
    /// screen and, more importantly, whatever delete-my-data control ships alongside a backend.
    var allNotes: [TransferNote] {
        notes.values.sorted { $0.recordedAt > $1.recordedAt }
    }

    func forgetEverything() {
        notes = [:]
        defaults.removeObject(forKey: Self.storageKey)
    }
}
