import Foundation

struct TranslationClientConfiguration: Equatable, Sendable {
    let sourceIdentifier: String
    let targetIdentifier: String

    init(_ pair: LanguagePairConfiguration) {
        sourceIdentifier = pair.sourceTranslationLanguageIdentifier
        targetIdentifier = pair.targetTranslationLanguageIdentifier
    }
}

struct PassThroughTranslationClient: CaptionTranslating {
    func translate(_ text: String) async throws -> String {
        text
    }
}
