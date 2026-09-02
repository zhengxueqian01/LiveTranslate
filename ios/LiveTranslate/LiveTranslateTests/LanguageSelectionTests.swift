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

    private func isolatedDefaults() -> UserDefaults {
        let suiteName = "LanguageConfigurationStoreTests.\(UUID().uuidString)"
        addTeardownBlock {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }
        return UserDefaults(suiteName: suiteName)!
    }
}
