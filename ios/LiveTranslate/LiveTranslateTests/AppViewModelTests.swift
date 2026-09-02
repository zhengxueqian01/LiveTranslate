import XCTest
@testable import LiveTranslate

@MainActor
final class AppViewModelTests: XCTestCase {
    func testOlderCaptionRevisionDoesNotReplaceLatestPreview() throws {
        let store = InMemoryCaptionStore()
        let viewModel = makeViewModel(store: store)
        let newestSnapshot = CaptionSnapshot(
            revision: 9,
            sourceText: "newest",
            translatedText: "最新",
            phase: .translating,
            errorMessage: nil,
            updatedAt: .now
        )
        let olderSnapshot = CaptionSnapshot(
            revision: 8,
            sourceText: "older",
            translatedText: "旧的",
            phase: .translating,
            errorMessage: nil,
            updatedAt: .now
        )

        try store.save(newestSnapshot)
        viewModel.refreshCaption()
        try store.save(olderSnapshot)
        viewModel.refreshCaption()

        XCTAssertEqual(viewModel.latestSnapshot, newestSnapshot)
    }

    func testCaptionObservationRefreshesSharedStoreAfterPollingInterval() async throws {
        let store = InMemoryCaptionStore()
        let viewModel = makeViewModel(store: store)
        let snapshot = CaptionSnapshot(
            revision: 7,
            sourceText: "Hello",
            translatedText: "你好",
            phase: .translating,
            errorMessage: nil,
            updatedAt: .now
        )
        try store.save(snapshot)

        viewModel.startCaptionObservation()
        defer { viewModel.stopCaptionObservation() }
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(viewModel.latestSnapshot, snapshot)
    }

    func testStoppingCaptionObservationPreventsSubsequentStoreRefreshes() async throws {
        let store = InMemoryCaptionStore()
        let viewModel = makeViewModel(store: store)
        let snapshot = CaptionSnapshot(
            revision: 9,
            sourceText: "Goodbye",
            translatedText: "再见",
            phase: .translating,
            errorMessage: nil,
            updatedAt: .now
        )

        viewModel.startCaptionObservation()
        viewModel.stopCaptionObservation()
        try store.save(snapshot)
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertNil(viewModel.latestSnapshot)
    }

    func testLoadingLanguagesDoesNotPrepareResources() async {
        let resources = RecordingLanguageResourceService()
        await resources.setState(
            .init(speech: .init(status: .needsDownload, isReserved: false), translation: .needsDownload),
            for: LanguageTestFixture.pair
        )
        let viewModel = AppViewModel(
            catalogService: FixedLanguageCatalogService(snapshot: LanguageTestFixture.catalog),
            resourceService: resources,
            store: InMemoryCaptionStore(),
            languageStore: InMemoryLanguageConfigurationStore(value: LanguageTestFixture.pair),
            displayLocale: Locale(identifier: "zh-Hans")
        )

        await viewModel.loadLanguages()

        let preparedSpeechLocales = await resources.preparedSpeechLocales
        XCTAssertEqual(preparedSpeechLocales, [])
        XCTAssertFalse(viewModel.canStartBroadcast)
    }

    func testExplicitPreparationInstallsSpeechThenRequestsTranslation() async {
        let resources = RecordingLanguageResourceService()
        await resources.setState(
            .init(speech: .init(status: .needsDownload, isReserved: false), translation: .needsDownload),
            for: LanguageTestFixture.pair
        )
        let viewModel = AppViewModel(
            catalogService: FixedLanguageCatalogService(snapshot: LanguageTestFixture.catalog),
            resourceService: resources,
            store: InMemoryCaptionStore(),
            languageStore: InMemoryLanguageConfigurationStore(value: LanguageTestFixture.pair),
            displayLocale: Locale(identifier: "zh-Hans")
        )
        await viewModel.loadLanguages()

        let action = await viewModel.beginModelPreparation()

        let preparedSpeechLocales = await resources.preparedSpeechLocales
        XCTAssertEqual(preparedSpeechLocales, ["fr-FR"])
        guard case .prepareTranslation(let request) = action else {
            XCTFail("Expected a translation preparation request")
            return
        }
        XCTAssertEqual(request.configuration, LanguageTestFixture.pair)
    }

    func testUnknownPairStatusCannotPrepareSpeech() async {
        let resources = RecordingLanguageResourceService()
        let viewModel = AppViewModel(
            catalogService: FixedLanguageCatalogService(snapshot: LanguageTestFixture.catalog),
            resourceService: resources,
            store: InMemoryCaptionStore(),
            languageStore: InMemoryLanguageConfigurationStore(value: LanguageTestFixture.pair),
            displayLocale: Locale(identifier: "zh-Hans")
        )
        await viewModel.loadLanguages()

        let action = await viewModel.beginModelPreparation()

        let preparedSpeechLocales = await resources.preparedSpeechLocales
        XCTAssertEqual(action, .none)
        XCTAssertEqual(preparedSpeechLocales, [])
    }

    func testUnsupportedPairCannotPrepareOrBroadcast() async {
        let resources = RecordingLanguageResourceService()
        await resources.setState(
            .init(speech: .init(status: .installed, isReserved: true), translation: .unsupported),
            for: LanguageTestFixture.pair
        )
        let viewModel = AppViewModel(
            catalogService: FixedLanguageCatalogService(snapshot: LanguageTestFixture.catalog),
            resourceService: resources,
            store: InMemoryCaptionStore(),
            languageStore: InMemoryLanguageConfigurationStore(value: LanguageTestFixture.pair),
            displayLocale: Locale(identifier: "zh-Hans")
        )
        await viewModel.loadLanguages()

        let action = await viewModel.beginModelPreparation()
        XCTAssertEqual(action, .none)
        XCTAssertFalse(viewModel.canStartBroadcast)
    }

    func testChangingOutputPersistsTheFullPair() async {
        let chinese = TranslationLanguageOption(languageIdentifier: "zh-Hans", displayName: "简体中文")
        let catalog = LanguageCatalogSnapshot(
            inputLanguages: [LanguageTestFixture.input],
            outputLanguages: [LanguageTestFixture.output, chinese]
        )
        let store = InMemoryLanguageConfigurationStore(value: LanguageTestFixture.pair)
        let viewModel = AppViewModel(
            catalogService: FixedLanguageCatalogService(snapshot: catalog),
            resourceService: RecordingLanguageResourceService(),
            store: InMemoryCaptionStore(),
            languageStore: store,
            displayLocale: Locale(identifier: "zh-Hans")
        )
        await viewModel.loadLanguages()

        await viewModel.selectOutput(identifier: "zh-Hans")

        XCTAssertEqual(store.load()?.targetTranslationLanguageIdentifier, "zh-Hans")
    }

    func testPassThroughPairNeedsNoTranslationTask() async {
        let frenchOutput = TranslationLanguageOption(languageIdentifier: "fr", displayName: "法语")
        let pair = LanguagePairConfiguration(
            sourceSpeechLocaleIdentifier: "fr-FR",
            sourceTranslationLanguageIdentifier: "fr",
            targetTranslationLanguageIdentifier: "fr"
        )
        let resources = RecordingLanguageResourceService()
        await resources.setState(
            .init(speech: .init(status: .installed, isReserved: true), translation: .notRequired),
            for: pair
        )
        let viewModel = AppViewModel(
            catalogService: FixedLanguageCatalogService(
                snapshot: .init(
                    inputLanguages: [LanguageTestFixture.input],
                    outputLanguages: [frenchOutput]
                )
            ),
            resourceService: resources,
            store: InMemoryCaptionStore(),
            languageStore: InMemoryLanguageConfigurationStore(value: pair),
            displayLocale: Locale(identifier: "zh-Hans")
        )
        await viewModel.loadLanguages()

        let action = await viewModel.beginModelPreparation()
        XCTAssertEqual(action, .none)
        XCTAssertTrue(viewModel.canStartBroadcast)
    }

    func testOldSpeechPreparationFailureDoesNotOverwriteCurrentPairState() async {
        let japanese = SpeechLanguageOption(
            localeIdentifier: "ja-JP",
            translationLanguageIdentifier: "ja",
            displayName: "日语（日本）"
        )
        let japanesePair = LanguagePairConfiguration(
            sourceSpeechLocaleIdentifier: "ja-JP",
            sourceTranslationLanguageIdentifier: "ja",
            targetTranslationLanguageIdentifier: "de"
        )
        let catalog = LanguageCatalogSnapshot(
            inputLanguages: [LanguageTestFixture.input, japanese],
            outputLanguages: [LanguageTestFixture.output]
        )
        let resources = ControlledLanguageResourceService()
        let viewModel = AppViewModel(
            catalogService: FixedLanguageCatalogService(snapshot: catalog),
            resourceService: resources,
            store: InMemoryCaptionStore(),
            languageStore: InMemoryLanguageConfigurationStore(value: LanguageTestFixture.pair),
            displayLocale: Locale(identifier: "zh-Hans")
        )
        let loading = Task { await viewModel.loadLanguages() }
        await resources.waitForStatusRequest(for: LanguageTestFixture.pair)
        await resources.resolveStatus(
            for: LanguageTestFixture.pair,
            with: .init(
                speech: .init(status: .needsDownload, isReserved: false),
                translation: .needsDownload
            )
        )
        await loading.value
        let preparation = Task { await viewModel.beginModelPreparation() }
        await resources.waitForPreparationRequest(for: LanguageTestFixture.pair)

        let selection = Task { await viewModel.selectInput(identifier: "ja-JP") }
        await resources.waitForStatusRequest(for: japanesePair)
        await resources.resolveStatus(
            for: japanesePair,
            with: .init(
                speech: .init(status: .installed, isReserved: true),
                translation: .installed
            )
        )
        await selection.value
        await resources.failPreparation(for: LanguageTestFixture.pair)
        _ = await preparation.value

        XCTAssertEqual(viewModel.currentConfiguration, japanesePair)
        XCTAssertTrue(viewModel.resourceState.isReady)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testLateResourceStatusForOldPairDoesNotOverwriteCurrentPair() async {
        let chinese = TranslationLanguageOption(languageIdentifier: "zh-Hans", displayName: "简体中文")
        let chinesePair = LanguagePairConfiguration(
            sourceSpeechLocaleIdentifier: "fr-FR",
            sourceTranslationLanguageIdentifier: "fr",
            targetTranslationLanguageIdentifier: "zh-Hans"
        )
        let catalog = LanguageCatalogSnapshot(
            inputLanguages: [LanguageTestFixture.input],
            outputLanguages: [LanguageTestFixture.output, chinese]
        )
        let resources = ControlledLanguageResourceService()
        let viewModel = AppViewModel(
            catalogService: FixedLanguageCatalogService(snapshot: catalog),
            resourceService: resources,
            store: InMemoryCaptionStore(),
            languageStore: InMemoryLanguageConfigurationStore(value: LanguageTestFixture.pair),
            displayLocale: Locale(identifier: "zh-Hans")
        )
        let loading = Task { await viewModel.loadLanguages() }
        await resources.waitForStatusRequest(for: LanguageTestFixture.pair)
        await resources.resolveStatus(
            for: LanguageTestFixture.pair,
            with: .init(
                speech: .init(status: .installed, isReserved: true),
                translation: .installed
            )
        )
        await loading.value

        let oldRequest = Task { await viewModel.selectOutput(identifier: "de") }
        await resources.waitForStatusRequest(for: LanguageTestFixture.pair)
        let currentRequest = Task { await viewModel.selectOutput(identifier: "zh-Hans") }
        await resources.waitForStatusRequest(for: chinesePair)
        await resources.resolveStatus(
            for: chinesePair,
            with: .init(
                speech: .init(status: .installed, isReserved: true),
                translation: .installed
            )
        )
        await currentRequest.value
        await resources.resolveStatus(
            for: LanguageTestFixture.pair,
            with: .init(
                speech: .init(status: .needsDownload, isReserved: false),
                translation: .needsDownload
            )
        )
        await oldRequest.value

        XCTAssertEqual(viewModel.currentConfiguration, chinesePair)
        XCTAssertTrue(viewModel.resourceState.isReady)
    }

    func testOldTranslationCompletionDoesNotOverwriteCurrentPair() async {
        let chinese = TranslationLanguageOption(languageIdentifier: "zh-Hans", displayName: "简体中文")
        let resources = RecordingLanguageResourceService()
        await resources.setState(
            .init(
                speech: .init(status: .installed, isReserved: true),
                translation: .needsDownload
            ),
            for: LanguageTestFixture.pair
        )
        let catalog = LanguageCatalogSnapshot(
            inputLanguages: [LanguageTestFixture.input],
            outputLanguages: [LanguageTestFixture.output, chinese]
        )
        let viewModel = AppViewModel(
            catalogService: FixedLanguageCatalogService(snapshot: catalog),
            resourceService: resources,
            store: InMemoryCaptionStore(),
            languageStore: InMemoryLanguageConfigurationStore(value: LanguageTestFixture.pair),
            displayLocale: Locale(identifier: "zh-Hans")
        )
        await viewModel.loadLanguages()
        let action = await viewModel.beginModelPreparation()
        guard case .prepareTranslation(let request) = action else {
            XCTFail("Expected a translation preparation request")
            return
        }
        await viewModel.selectOutput(identifier: "zh-Hans")

        await viewModel.finishTranslationPreparation(
            for: request,
            error: ModelPreparationTestError.installationFailed
        )

        XCTAssertNil(viewModel.errorMessage)
    }

    func testOldTranslationCompletionForSamePairCannotAffectNewPreparation() async {
        let chinese = TranslationLanguageOption(languageIdentifier: "zh-Hans", displayName: "简体中文")
        let chinesePair = LanguagePairConfiguration(
            sourceSpeechLocaleIdentifier: "fr-FR",
            sourceTranslationLanguageIdentifier: "fr",
            targetTranslationLanguageIdentifier: "zh-Hans"
        )
        let catalog = LanguageCatalogSnapshot(
            inputLanguages: [LanguageTestFixture.input],
            outputLanguages: [LanguageTestFixture.output, chinese]
        )
        let resources = RecordingLanguageResourceService()
        let needsTranslation = LanguagePairResourceState(
            speech: .init(status: .installed, isReserved: true),
            translation: .needsDownload
        )
        await resources.setState(needsTranslation, for: LanguageTestFixture.pair)
        await resources.setState(needsTranslation, for: chinesePair)
        let viewModel = AppViewModel(
            catalogService: FixedLanguageCatalogService(snapshot: catalog),
            resourceService: resources,
            store: InMemoryCaptionStore(),
            languageStore: InMemoryLanguageConfigurationStore(value: LanguageTestFixture.pair),
            displayLocale: Locale(identifier: "zh-Hans")
        )
        await viewModel.loadLanguages()

        let oldAction = await viewModel.beginModelPreparation()
        guard case .prepareTranslation(let oldRequest) = oldAction else {
            XCTFail("Expected the old translation preparation request")
            return
        }
        await viewModel.selectOutput(identifier: "zh-Hans")
        await viewModel.selectOutput(identifier: "de")
        let newAction = await viewModel.beginModelPreparation()
        guard case .prepareTranslation(let newRequest) = newAction else {
            XCTFail("Expected the new translation preparation request")
            return
        }
        XCTAssertNotEqual(oldRequest.token, newRequest.token)

        await viewModel.finishTranslationPreparation(
            for: oldRequest,
            error: ModelPreparationTestError.installationFailed
        )

        XCTAssertEqual(viewModel.preparationPhase, .preparingTranslation)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.resourceState, needsTranslation)
    }

    func testStorageFailureRetainsPriorityOverTranslationFailure() async {
        let resources = RecordingLanguageResourceService()
        await resources.setState(
            .init(speech: .init(status: .installed, isReserved: true), translation: .needsDownload),
            for: LanguageTestFixture.pair
        )
        let viewModel = AppViewModel(
            catalogService: FixedLanguageCatalogService(snapshot: LanguageTestFixture.catalog),
            resourceService: resources,
            store: nil,
            languageStore: InMemoryLanguageConfigurationStore(value: LanguageTestFixture.pair),
            displayLocale: Locale(identifier: "zh-Hans")
        )
        await viewModel.loadLanguages()
        let action = await viewModel.beginModelPreparation()
        guard case .prepareTranslation(let request) = action else {
            XCTFail("Expected a translation preparation request")
            return
        }

        await viewModel.finishTranslationPreparation(
            for: request,
            error: ModelPreparationTestError.installationFailed
        )

        XCTAssertFalse(viewModel.canStartBroadcast)
        XCTAssertEqual(
            viewModel.errorMessage,
            "无法打开 App Group，请检查两个 Target 的签名与 App Group 配置。"
        )
    }

    func testEmptyCatalogReportsErrorAndDisablesBroadcast() async {
        let viewModel = AppViewModel(
            catalogService: FixedLanguageCatalogService(
                snapshot: .init(inputLanguages: [], outputLanguages: [])
            ),
            resourceService: RecordingLanguageResourceService(),
            store: InMemoryCaptionStore(),
            languageStore: InMemoryLanguageConfigurationStore(),
            displayLocale: Locale(identifier: "zh-Hans")
        )

        await viewModel.loadLanguages()

        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.canStartBroadcast)
        XCTAssertNil(viewModel.currentConfiguration)
    }

    private func makeViewModel(
        store: (any CaptionStoreProtocol)? = InMemoryCaptionStore()
    ) -> AppViewModel {
        AppViewModel(
            catalogService: FixedLanguageCatalogService(snapshot: LanguageTestFixture.catalog),
            resourceService: RecordingLanguageResourceService(),
            store: store,
            languageStore: InMemoryLanguageConfigurationStore(value: LanguageTestFixture.pair),
            displayLocale: Locale(identifier: "zh-Hans")
        )
    }
}
