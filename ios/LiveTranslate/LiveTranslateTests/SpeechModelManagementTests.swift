import XCTest
@testable import LiveTranslate

@MainActor
final class SpeechModelManagementTests: XCTestCase {
    func testReleasingCurrentSpeechLocaleDisablesBroadcast() async {
        let input = SpeechLanguageOption(
            localeIdentifier: "en-US",
            translationLanguageIdentifier: "en",
            displayName: "英语（美国）"
        )
        let output = TranslationLanguageOption(
            languageIdentifier: "zh-Hans",
            displayName: "简体中文"
        )
        let pair = LanguagePairConfiguration(
            sourceSpeechLocaleIdentifier: "en-US",
            sourceTranslationLanguageIdentifier: "en",
            targetTranslationLanguageIdentifier: "zh-Hans"
        )
        let resourceService = RecordingLanguageResourceService()
        await resourceService.setState(
            .init(
                speech: .init(status: .installed, isReserved: true),
                translation: .installed
            ),
            for: pair
        )
        await resourceService.setReservedLocales(["en-US"])
        let viewModel = AppViewModel(
            catalogService: FixedLanguageCatalogService(
                snapshot: .init(inputLanguages: [input], outputLanguages: [output])
            ),
            resourceService: resourceService,
            store: InMemoryCaptionStore(),
            languageStore: InMemoryLanguageConfigurationStore(value: pair),
            displayLocale: Locale(identifier: "zh-Hans")
        )
        await viewModel.loadLanguages()
        await viewModel.loadReservedSpeechLocales()

        XCTAssertTrue(viewModel.canStartBroadcast)
        XCTAssertEqual(viewModel.reservedSpeechLocaleIdentifiers, ["en-US"])

        await viewModel.releaseSpeechLocale("en-US")

        XCTAssertFalse(viewModel.canStartBroadcast)
        XCTAssertEqual(viewModel.reservedSpeechLocaleIdentifiers, [])
    }

    func testReleasingSpeechLocaleIsBlockedDuringActiveBroadcast() async throws {
        for phase: SessionPhase in [.broadcasting, .recognizing, .translating] {
            let store = InMemoryCaptionStore()
            try store.save(.init(
                revision: 3,
                sourceText: "live",
                translatedText: "直播",
                phase: phase,
                errorMessage: nil,
                updatedAt: .now
            ))
            let resourceService = RecordingLanguageResourceService()
            await resourceService.setState(
                .init(
                    speech: .init(status: .installed, isReserved: true),
                    translation: .installed
                ),
                for: LanguageTestFixture.pair
            )
            let viewModel = AppViewModel(
                catalogService: FixedLanguageCatalogService(snapshot: LanguageTestFixture.catalog),
                resourceService: resourceService,
                store: store,
                languageStore: InMemoryLanguageConfigurationStore(value: LanguageTestFixture.pair),
                displayLocale: Locale(identifier: "zh-Hans")
            )
            await viewModel.loadLanguages()
            viewModel.refreshCaption()

            await viewModel.releaseSpeechLocale("fr-FR")

            XCTAssertTrue(viewModel.canStartBroadcast, "Unexpected release in \(phase)")
        }
    }
}
