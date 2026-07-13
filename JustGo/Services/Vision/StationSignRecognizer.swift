import CoreVideo
import Foundation
import ImageIO
import Vision

struct StationSignCandidate: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let title: String
    let aliases: [String]

    init(node: IndoorNode) {
        id = node.id
        title = node.title
        aliases = node.resolvedRecognitionAliases
    }
}

enum StationSignRecognitionOutcome: Equatable, Sendable {
    case unique(StationSignCandidate)
    case ambiguous([StationSignCandidate])
    case none
}

/// Runs Apple's text recognizer entirely on the current video frame. Raw frames and
/// recognized strings stay local to `recognize` and are released before the method returns.
struct StationSignRecognizer {
    func recognize(
        pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation,
        candidates: [StationSignCandidate]
    ) -> StationSignRecognitionOutcome {
        guard !candidates.isEmpty else { return .none }

        var recognizedLines: [String] = []
        let request = VNRecognizeTextRequest { request, error in
            guard error == nil,
                  let observations = request.results as? [VNRecognizedTextObservation] else { return }
            recognizedLines = observations.compactMap { $0.topCandidates(1).first?.string }
        }
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.025

        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: orientation,
            options: [:]
        )
        do {
            try handler.perform([request])
        } catch {
            return .none
        }

        return Self.outcome(for: recognizedLines, candidates: candidates)
    }

    /// Deterministic matching makes a frame with one authored checkpoint, several authored
    /// checkpoints, or no authored checkpoint produce a stable semantic outcome.
    static func outcome(
        for recognizedLines: [String],
        candidates: [StationSignCandidate]
    ) -> StationSignRecognitionOutcome {
        let normalizedLines = recognizedLines
            .map(normalize)
            .filter { !$0.isEmpty }

        var seen = Set<String>()
        let matches = candidates.filter { candidate in
            guard seen.insert(candidate.id).inserted else { return false }
            return candidate.aliases.contains { alias in
                let normalizedAlias = normalize(alias)
                guard !normalizedAlias.isEmpty else { return false }
                return normalizedLines.contains { $0.contains(normalizedAlias) }
            }
        }

        switch matches.count {
        case 0: return .none
        case 1: return .unique(matches[0])
        default: return .ambiguous(matches)
        }
    }

    private static func normalize(_ value: String) -> String {
        let folded = value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        let scalars = folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        return String(String.UnicodeScalarView(scalars))
    }
}

/// Requires the same semantic result across consecutive sampled frames so OCR jitter never
/// flips the confirmation UI between unique, ambiguous, and no-match states.
struct StationSignRecognitionStabilizer {
    private var pending: StationSignRecognitionOutcome?
    private var consecutiveCount = 0

    mutating func ingest(_ outcome: StationSignRecognitionOutcome) -> StationSignRecognitionOutcome? {
        if pending == outcome {
            consecutiveCount += 1
        } else {
            pending = outcome
            consecutiveCount = 1
        }

        let requiredCount = outcome == .none ? 4 : 2
        return consecutiveCount >= requiredCount ? outcome : nil
    }

    mutating func reset() {
        pending = nil
        consecutiveCount = 0
    }
}
