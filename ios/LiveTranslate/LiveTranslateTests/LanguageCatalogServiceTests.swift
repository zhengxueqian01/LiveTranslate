import Foundation
import XCTest
@testable import LiveTranslate

final class LanguageCatalogServiceTests: XCTestCase {
    func testBuilderMapsSpeechLocalesToTranslationLanguages() {
        let catalog = LanguageCatalogBuilder.build(
            speechLocaleIdentifiers: ["ja-JP", "en-US", "zh-TW", "xx-YY"],
            translationLanguageIdentifiers: ["en", "ja", "zh-Hant", "de"],
            displayLocale: Locale(identifier: "zh-Hans")
        )

        XCTAssertEqual(Set(catalog.inputLanguages.map(\.localeIdentifier)), ["en-US", "ja-JP", "zh-TW"])
        XCTAssertEqual(
            catalog.inputLanguages.first { $0.localeIdentifier == "zh-TW" }?.translationLanguageIdentifier,
            "zh-Hant"
        )
    }

    func testBuilderDeduplicatesIdentifiersAndProducesNames() {
        let catalog = LanguageCatalogBuilder.build(
            speechLocaleIdentifiers: ["ja-JP", "ja-JP"],
            translationLanguageIdentifiers: ["ja", "ja"],
            displayLocale: Locale(identifier: "zh-Hans")
        )

        XCTAssertEqual(catalog.inputLanguages.count, 1)
        XCTAssertEqual(catalog.outputLanguages.count, 1)
        XCTAssertFalse(catalog.inputLanguages[0].displayName.isEmpty)
    }
}
