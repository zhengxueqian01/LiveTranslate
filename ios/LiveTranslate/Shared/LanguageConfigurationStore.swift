import Foundation

protocol LanguageConfigurationStoring: Sendable {
    func load() -> LanguagePairConfiguration?
    func save(_ configuration: LanguagePairConfiguration)
}

final class LanguageConfigurationStore: LanguageConfigurationStoring, @unchecked Sendable {
    static let configurationKey = "language.configuration.v1"
    static let legacySourceKey = "source.language"

    private let defaults: UserDefaults

    convenience init() throws {
        guard let defaults = UserDefaults(suiteName: CaptionStore.appGroupIdentifier) else {
            throw CaptionStoreError.appGroupUnavailable
        }
        self.init(defaults: defaults)
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func load() -> LanguagePairConfiguration? {
        if let data = defaults.data(forKey: Self.configurationKey),
           let value = try? PropertyListDecoder().decode(LanguagePairConfiguration.self, from: data),
           value.schemaVersion == LanguagePairConfiguration.currentSchemaVersion {
            return value
        }

        guard let legacy = defaults.string(forKey: Self.legacySourceKey) else { return nil }

        let migrated: LanguagePairConfiguration?
        switch legacy {
        case "en-US":
            migrated = .init(
                sourceSpeechLocaleIdentifier: "en-US",
                sourceTranslationLanguageIdentifier: "en",
                targetTranslationLanguageIdentifier: "zh-Hans"
            )
        case "ja-JP":
            migrated = .init(
                sourceSpeechLocaleIdentifier: "ja-JP",
                sourceTranslationLanguageIdentifier: "ja",
                targetTranslationLanguageIdentifier: "zh-Hans"
            )
        default:
            migrated = nil
        }

        if let migrated { save(migrated) }
        return migrated
    }

    func save(_ configuration: LanguagePairConfiguration) {
        guard let data = try? PropertyListEncoder().encode(configuration) else { return }
        defaults.set(data, forKey: Self.configurationKey)
    }
}
