import Foundation

enum LanguageConfigurationLoadResult: Equatable, Sendable {
    case missing
    case invalid
    case configuration(LanguagePairConfiguration)
}

protocol LanguageConfigurationStoring: Sendable {
    func loadResult() -> LanguageConfigurationLoadResult
    func save(_ configuration: LanguagePairConfiguration)
}

extension LanguageConfigurationStoring {
    func load() -> LanguagePairConfiguration? {
        guard case .configuration(let configuration) = loadResult() else {
            return nil
        }
        return configuration
    }
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

    func loadResult() -> LanguageConfigurationLoadResult {
        if defaults.object(forKey: Self.configurationKey) != nil {
            guard let data = defaults.data(forKey: Self.configurationKey),
                  let value = try? PropertyListDecoder().decode(
                      LanguagePairConfiguration.self,
                      from: data
                  ),
                  value.schemaVersion == LanguagePairConfiguration.currentSchemaVersion else {
                return .invalid
            }
            return .configuration(value)
        }

        guard defaults.object(forKey: Self.legacySourceKey) != nil else {
            return .missing
        }
        guard let legacy = defaults.string(forKey: Self.legacySourceKey) else {
            return .invalid
        }

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

        guard let migrated else { return .invalid }
        save(migrated)
        return .configuration(migrated)
    }

    func save(_ configuration: LanguagePairConfiguration) {
        guard let data = try? PropertyListEncoder().encode(configuration) else { return }
        defaults.set(data, forKey: Self.configurationKey)
    }
}
