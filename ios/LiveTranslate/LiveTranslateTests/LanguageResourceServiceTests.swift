import XCTest
@testable import LiveTranslate

final class LanguageResourceServiceTests: XCTestCase {
    func testReadyRequiresInstalledReservedSpeechAndTranslation() {
        XCTAssertFalse(LanguagePairResourceState(
            speech: .init(status: .installed, isReserved: false),
            translation: .installed
        ).isReady)
        XCTAssertTrue(LanguagePairResourceState(
            speech: .init(status: .installed, isReserved: true),
            translation: .installed
        ).isReady)
    }

    func testPassThroughDoesNotRequireTranslationModel() {
        XCTAssertTrue(LanguagePairResourceState(
            speech: .init(status: .installed, isReserved: true),
            translation: .notRequired
        ).isReady)
    }
}
