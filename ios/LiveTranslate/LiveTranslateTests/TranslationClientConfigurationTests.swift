import XCTest
@testable import LiveTranslate

final class TranslationClientConfigurationTests: XCTestCase {
    func testTranslationClientConfigurationUsesStoredPair() {
        let pair = LanguagePairConfiguration(
            sourceSpeechLocaleIdentifier: "fr-FR",
            sourceTranslationLanguageIdentifier: "fr",
            targetTranslationLanguageIdentifier: "de"
        )

        XCTAssertEqual(TranslationClientConfiguration(pair).sourceIdentifier, "fr")
        XCTAssertEqual(TranslationClientConfiguration(pair).targetIdentifier, "de")
    }

    func testPassThroughTranslatorReturnsRecognizedText() async throws {
        let translatedText = try await PassThroughTranslationClient().translate("同じ言語")

        XCTAssertEqual(translatedText, "同じ言語")
    }
}
