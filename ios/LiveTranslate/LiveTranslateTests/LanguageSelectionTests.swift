import Foundation
import XCTest
@testable import LiveTranslate

final class LanguageSelectionTests: XCTestCase {
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
