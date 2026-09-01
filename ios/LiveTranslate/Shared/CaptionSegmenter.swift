import Foundation

struct TranslationCandidate: Equatable, Sendable {
    let revision: UInt64
    let text: String
}

struct SegmentUpdate: Equatable, Sendable {
    let displayText: String
    let translationCandidate: TranslationCandidate?
}

struct CaptionSegmenter: Sendable {
    private let minimumIntervalMilliseconds: UInt64
    private var displayedText = ""
    private var lastCandidateText = ""
    private var lastCandidateWasFinal = false
    private var firstPendingTimestamp: UInt64?
    private var lastCandidateTimestamp: UInt64?
    private var nextRevision: UInt64 = 1

    init(minimumIntervalMilliseconds: UInt64) {
        self.minimumIntervalMilliseconds = minimumIntervalMilliseconds
    }

    mutating func ingest(
        text: String,
        isFinal: Bool,
        timestampMilliseconds: UInt64
    ) -> SegmentUpdate? {
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty else {
            return nil
        }

        let isRepeatedText = normalizedText == displayedText
        guard !isRepeatedText || isFinal else {
            return nil
        }

        if !isRepeatedText {
            displayedText = normalizedText
            firstPendingTimestamp = firstPendingTimestamp ?? timestampMilliseconds
        }

        if isFinal {
            guard normalizedText != lastCandidateText || !lastCandidateWasFinal else {
                return nil
            }
            return makeCandidateUpdate(
                text: normalizedText,
                isFinal: true,
                timestampMilliseconds: timestampMilliseconds
            )
        }

        guard normalizedText.count >= 4 else {
            return SegmentUpdate(displayText: normalizedText, translationCandidate: nil)
        }

        let intervalStart = lastCandidateTimestamp ?? firstPendingTimestamp ?? timestampMilliseconds
        guard timestampMilliseconds >= intervalStart,
              timestampMilliseconds - intervalStart >= minimumIntervalMilliseconds else {
            return SegmentUpdate(displayText: normalizedText, translationCandidate: nil)
        }

        return makeCandidateUpdate(
            text: normalizedText,
            isFinal: false,
            timestampMilliseconds: timestampMilliseconds
        )
    }

    private mutating func makeCandidateUpdate(
        text: String,
        isFinal: Bool,
        timestampMilliseconds: UInt64
    ) -> SegmentUpdate {
        let candidate = TranslationCandidate(revision: nextRevision, text: text)
        nextRevision += 1
        lastCandidateText = text
        lastCandidateWasFinal = isFinal
        lastCandidateTimestamp = timestampMilliseconds
        firstPendingTimestamp = nil
        return SegmentUpdate(displayText: text, translationCandidate: candidate)
    }
}
