import Foundation
import XCTest
@testable import LiveTranslate

final class LanguageSelectionTests: XCTestCase {
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
}
