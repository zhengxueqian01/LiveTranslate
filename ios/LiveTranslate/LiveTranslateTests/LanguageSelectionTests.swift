import Foundation
import XCTest
@testable import LiveTranslate

final class LanguageSelectionTests: XCTestCase {
    func testConfigurationRoundTripsThroughSharedDefaults() {
        let defaults = isolatedDefaults()
        let store = LanguageConfigurationStore(defaults: defaults)
        let value = LanguagePairConfiguration(
            sourceSpeechLocaleIdentifier: "fr-FR",
            sourceTranslationLanguageIdentifier: "fr",
            targetTranslationLanguageIdentifier: "de"
        )

        store.save(value)

        XCTAssertEqual(store.load(), value)
    }

    func testLegacyJapaneseSelectionMigrates() {
        let defaults = isolatedDefaults()
        defaults.set("ja-JP", forKey: LanguageConfigurationStore.legacySourceKey)

        XCTAssertEqual(
            LanguageConfigurationStore(defaults: defaults).load(),
            LanguagePairConfiguration(
                sourceSpeechLocaleIdentifier: "ja-JP",
                sourceTranslationLanguageIdentifier: "ja",
                targetTranslationLanguageIdentifier: "zh-Hans"
            )
        )
    }

    func testUnknownLegacySelectionDoesNotMigrate() {
        let defaults = isolatedDefaults()
        defaults.set("invalid", forKey: LanguageConfigurationStore.legacySourceKey)

        XCTAssertNil(LanguageConfigurationStore(defaults: defaults).load())
    }

    func testSourceLanguageRoundTripsThroughSharedDefaults() {
        let suiteName = "SourceLanguageStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SourceLanguageStore(defaults: defaults)
        store.save(.japanese)

        XCTAssertEqual(defaults.string(forKey: "source.language"), "ja-JP")
        XCTAssertEqual(store.load(), .japanese)
    }

    func testSupportedLanguagesMapToExpectedLocales() {
        XCTAssertEqual(SourceLanguage.english.speechLocale.identifier, "en-US")
        XCTAssertEqual(SourceLanguage.japanese.speechLocale.identifier, "ja-JP")
        XCTAssertEqual(SourceLanguage.english.translationSource.minimalIdentifier, "en")
        XCTAssertEqual(SourceLanguage.japanese.translationSource.minimalIdentifier, "ja")
        XCTAssertEqual(
            SourceLanguage.translationTarget,
            Locale.Language(identifier: "zh-Hans")
        )
    }

    private func isolatedDefaults() -> UserDefaults {
        let suiteName = "LanguageConfigurationStoreTests.\(UUID().uuidString)"
        addTeardownBlock {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }
        return UserDefaults(suiteName: suiteName)!
    }
}
