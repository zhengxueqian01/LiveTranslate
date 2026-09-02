import Foundation

struct SpeechLanguageOption: Codable, Hashable, Identifiable, Sendable {
    let localeIdentifier: String
    let translationLanguageIdentifier: String
    let displayName: String

    var id: String { localeIdentifier }
}

struct TranslationLanguageOption: Codable, Hashable, Identifiable, Sendable {
    let languageIdentifier: String
    let displayName: String

    var id: String { languageIdentifier }
}

struct LanguagePairConfiguration: Codable, Equatable, Hashable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let sourceSpeechLocaleIdentifier: String
    let sourceTranslationLanguageIdentifier: String
    let targetTranslationLanguageIdentifier: String

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        sourceSpeechLocaleIdentifier: String,
        sourceTranslationLanguageIdentifier: String,
        targetTranslationLanguageIdentifier: String
    ) {
        self.schemaVersion = schemaVersion
        self.sourceSpeechLocaleIdentifier = sourceSpeechLocaleIdentifier
        self.sourceTranslationLanguageIdentifier = sourceTranslationLanguageIdentifier
        self.targetTranslationLanguageIdentifier = targetTranslationLanguageIdentifier
    }

    var usesPassThroughTranslation: Bool {
        sourceTranslationLanguageIdentifier == targetTranslationLanguageIdentifier
    }
}
