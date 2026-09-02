import Foundation
@preconcurrency import Speech
@preconcurrency import Translation

struct LanguageCatalogSnapshot: Equatable, Sendable {
    let inputLanguages: [SpeechLanguageOption]
    let outputLanguages: [TranslationLanguageOption]
}

protocol LanguageCatalogProviding: Sendable {
    func load(displayLocale: Locale) async throws -> LanguageCatalogSnapshot
}

enum LanguageCatalogBuilder {
    static func build(
        speechLocaleIdentifiers: [String],
        translationLanguageIdentifiers: [String],
        displayLocale: Locale
    ) -> LanguageCatalogSnapshot {
        let supported = Set(translationLanguageIdentifiers)
        let inputs = Set(speechLocaleIdentifiers).compactMap { identifier -> SpeechLanguageOption? in
            let language = Locale(identifier: identifier).language
            let code = language.languageCode?.identifier
            let script = language.script?.identifier
            let candidates = [
                language.minimalIdentifier,
                code.flatMap { value in script.map { "\(value)-\($0)" } },
                code
            ].compactMap { $0 }
            guard let translationIdentifier = candidates.first(where: supported.contains) else {
                return nil
            }
            return SpeechLanguageOption(
                localeIdentifier: identifier,
                translationLanguageIdentifier: translationIdentifier,
                displayName: displayLocale.localizedString(forIdentifier: identifier) ?? identifier
            )
        }.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
        let outputs = supported.map {
            TranslationLanguageOption(
                languageIdentifier: $0,
                displayName: displayLocale.localizedString(forIdentifier: $0) ?? $0
            )
        }.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
        return .init(inputLanguages: inputs, outputLanguages: outputs)
    }
}

struct SystemLanguageCatalogService: LanguageCatalogProviding {
    func load(displayLocale: Locale) async throws -> LanguageCatalogSnapshot {
        let speechLocales = await SpeechTranscriber.supportedLocales
        let availability: LanguageAvailability
        if #available(iOS 26.4, *) {
            availability = LanguageAvailability(preferredStrategy: .lowLatency)
        } else {
            availability = LanguageAvailability()
        }
        let translationLanguages = await availability.supportedLanguages
        return LanguageCatalogBuilder.build(
            speechLocaleIdentifiers: speechLocales.map(\.identifier),
            translationLanguageIdentifiers: translationLanguages.map(\.minimalIdentifier),
            displayLocale: displayLocale
        )
    }
}
