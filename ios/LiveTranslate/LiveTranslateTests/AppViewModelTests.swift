import Combine
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

    func testPictureInPictureStopDoesNotTerminatePageCaptionObservation() async throws {
        let store = InMemoryCaptionStore()
        let viewModel = makeViewModel(store: store)
        let lifecycle = CaptionPreviewObservationLifecycle(viewModel: viewModel)
        let snapshot = CaptionSnapshot(
            revision: 10,
            sourceText: "Still updating",
            translatedText: "仍在更新",
            phase: .recognizing,
            errorMessage: nil,
            updatedAt: .now
        )
        let updateObserved = expectation(description: "Page preview receives the next snapshot")
        let observation = viewModel.$latestSnapshot
            .dropFirst()
            .sink { value in
                if value == snapshot {
                    updateObserved.fulfill()
                }
            }

        lifecycle.pageDidAppear()
        defer {
            lifecycle.pageDidDisappear()
            observation.cancel()
        }
        lifecycle.pictureInPictureDidStop()
        try store.save(snapshot)

        await fulfillment(of: [updateObserved], timeout: 1)
        XCTAssertEqual(viewModel.latestSnapshot, snapshot)
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

    func testStaleTranslationCompletionAfterRefreshDoesNotBlockNewSelection() async {
        let chinese = TranslationLanguageOption(
            languageIdentifier: "zh-Hans",
            displayName: "简体中文"
        )
        let chinesePair = LanguagePairConfiguration(
            sourceSpeechLocaleIdentifier: "fr-FR",
            sourceTranslationLanguageIdentifier: "fr",
            targetTranslationLanguageIdentifier: "zh-Hans"
        )
        let needsTranslation = LanguagePairResourceState(
            speech: .init(status: .installed, isReserved: true),
            translation: .needsDownload
        )
        let resources = ControlledLanguageResourceService()
        let viewModel = AppViewModel(
            catalogService: FixedLanguageCatalogService(
                snapshot: .init(
                    inputLanguages: [LanguageTestFixture.input],
                    outputLanguages: [LanguageTestFixture.output, chinese]
                )
            ),
            resourceService: resources,
            store: InMemoryCaptionStore(),
            languageStore: InMemoryLanguageConfigurationStore(value: LanguageTestFixture.pair),
            displayLocale: Locale(identifier: "zh-Hans")
        )
        let loading = Task { await viewModel.loadLanguages() }
        await resources.waitForStatusRequest(for: LanguageTestFixture.pair)
        await resources.resolveStatus(for: LanguageTestFixture.pair, with: needsTranslation)
        await loading.value

        let preparation = Task { await viewModel.beginModelPreparation() }
        await resources.waitForStatusRequest(for: LanguageTestFixture.pair)
        await resources.resolveStatus(for: LanguageTestFixture.pair, with: needsTranslation)
        guard case .prepareTranslation(let request) = await preparation.value else {
            XCTFail("Expected a translation preparation request")
            return
        }

        let completion = Task {
            await viewModel.finishTranslationPreparation(
                for: request,
                error: ModelPreparationTestError.installationFailed
            )
        }
        await resources.waitForStatusRequest(for: LanguageTestFixture.pair)

        let selection = Task { await viewModel.selectOutput(identifier: "zh-Hans") }
        await resources.waitForStatusRequest(for: chinesePair)
        await resources.resolveStatus(for: LanguageTestFixture.pair, with: needsTranslation)
        await completion.value

        XCTAssertEqual(viewModel.currentConfiguration, chinesePair)
        XCTAssertEqual(viewModel.preparationPhase, .idle)
        XCTAssertNil(viewModel.errorMessage)

        await resources.resolveStatus(
            for: chinesePair,
            with: .init(
                speech: .init(status: .installed, isReserved: true),
                translation: .installed
            )
        )
        await selection.value
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

    func testTranslationPreparationErrorDoesNotBlockInstalledPairAfterRefresh() async {
        let resources = RecordingLanguageResourceService()
        await resources.setState(
            .init(
                speech: .init(status: .installed, isReserved: true),
                translation: .needsDownload
            ),
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
        guard case .prepareTranslation(let request) = action else {
            XCTFail("Expected a translation preparation request")
            return
        }
        await resources.setState(
            .init(
                speech: .init(status: .installed, isReserved: true),
                translation: .installed
            ),
            for: LanguageTestFixture.pair
        )

        await viewModel.finishTranslationPreparation(
            for: request,
            error: ModelPreparationTestError.installationFailed
        )

        XCTAssertTrue(viewModel.resourceState.isReady)
        XCTAssertTrue(viewModel.canStartBroadcast)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testCaptionReadFailureIsInformationalAndClearsAfterSuccessfulRead() async throws {
        let snapshot = CaptionSnapshot(
            revision: 4,
            sourceText: "Recovered",
            translatedText: "已恢复",
            phase: .stopped,
            errorMessage: nil,
            updatedAt: .now
        )
        let store = RecoveringCaptionStore(snapshot: snapshot)
        let resources = RecordingLanguageResourceService()
        await resources.setState(
            .init(
                speech: .init(status: .installed, isReserved: true),
                translation: .installed
            ),
            for: LanguageTestFixture.pair
        )
        let viewModel = AppViewModel(
            catalogService: FixedLanguageCatalogService(snapshot: LanguageTestFixture.catalog),
            resourceService: resources,
            store: store,
            languageStore: InMemoryLanguageConfigurationStore(value: LanguageTestFixture.pair),
            displayLocale: Locale(identifier: "zh-Hans")
        )
        await viewModel.loadLanguages()

        viewModel.refreshCaption()

        XCTAssertTrue(viewModel.canStartBroadcast)
        XCTAssertNotNil(viewModel.errorMessage)

        viewModel.refreshCaption()

        XCTAssertTrue(viewModel.canStartBroadcast)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.latestSnapshot, snapshot)
    }

    func testSuccessfulCaptionReadDoesNotClearCatalogBlockingError() async {
        let snapshot = CaptionSnapshot(
            revision: 1,
            sourceText: "cached",
            translatedText: "缓存",
            phase: .stopped,
            errorMessage: nil,
            updatedAt: .now
        )
        let viewModel = AppViewModel(
            catalogService: FailingLanguageCatalogService(
                error: ModelPreparationTestError.catalogFailed
            ),
            resourceService: RecordingLanguageResourceService(),
            store: RecoveringCaptionStore(snapshot: snapshot),
            languageStore: InMemoryLanguageConfigurationStore(),
            displayLocale: Locale(identifier: "zh-Hans")
        )
        await viewModel.loadLanguages()

        viewModel.refreshCaption()
        viewModel.refreshCaption()

        XCTAssertFalse(viewModel.canStartBroadcast)
        XCTAssertEqual(
            viewModel.errorMessage,
            "语言列表加载失败：模拟目录加载失败"
        )
    }

    func testCorruptSavedConfigurationRequiresExplicitReselection() async {
        let defaults = isolatedDefaults()
        defaults.set(Data([0x00, 0x01]), forKey: LanguageConfigurationStore.configurationKey)
        let resources = RecordingLanguageResourceService()
        await resources.setState(
            .init(
                speech: .init(status: .installed, isReserved: true),
                translation: .installed
            ),
            for: LanguageTestFixture.pair
        )
        let viewModel = AppViewModel(
            catalogService: FixedLanguageCatalogService(snapshot: LanguageTestFixture.catalog),
            resourceService: resources,
            store: InMemoryCaptionStore(),
            languageStore: LanguageConfigurationStore(defaults: defaults),
            displayLocale: Locale(identifier: "zh-Hans")
        )

        await viewModel.loadLanguages()

        XCTAssertNil(viewModel.currentConfiguration)
        XCTAssertFalse(viewModel.canStartBroadcast)
        XCTAssertTrue(viewModel.errorMessage?.contains("重新选择") == true)

        await viewModel.selectInput(identifier: LanguageTestFixture.input.localeIdentifier)
        XCTAssertFalse(viewModel.canStartBroadcast)
        await viewModel.selectOutput(identifier: LanguageTestFixture.output.languageIdentifier)

        XCTAssertEqual(viewModel.currentConfiguration, LanguageTestFixture.pair)
        XCTAssertTrue(viewModel.canStartBroadcast)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testLoadLanguagesIfNeededPreservesPartialReselection() async {
        let defaults = isolatedDefaults()
        defaults.set(Data([0x00, 0x01]), forKey: LanguageConfigurationStore.configurationKey)
        let viewModel = AppViewModel(
            catalogService: FixedLanguageCatalogService(snapshot: LanguageTestFixture.catalog),
            resourceService: RecordingLanguageResourceService(),
            store: InMemoryCaptionStore(),
            languageStore: LanguageConfigurationStore(defaults: defaults),
            displayLocale: Locale(identifier: "zh-Hans")
        )
        await viewModel.loadLanguages()

        XCTAssertTrue(
            viewModel.setInputSelection(identifier: LanguageTestFixture.input.localeIdentifier)
        )
        await viewModel.loadLanguagesIfNeeded()

        XCTAssertEqual(viewModel.selectedInput, LanguageTestFixture.input)
        XCTAssertNil(viewModel.selectedOutput)
    }

    func testUnsupportedSavedConfigurationVersionDisablesBroadcast() async throws {
        let defaults = isolatedDefaults()
        let unsupported = LanguagePairConfiguration(
            schemaVersion: 999,
            sourceSpeechLocaleIdentifier: "fr-FR",
            sourceTranslationLanguageIdentifier: "fr",
            targetTranslationLanguageIdentifier: "de"
        )
        defaults.set(
            try PropertyListEncoder().encode(unsupported),
            forKey: LanguageConfigurationStore.configurationKey
        )
        let viewModel = AppViewModel(
            catalogService: FixedLanguageCatalogService(snapshot: LanguageTestFixture.catalog),
            resourceService: RecordingLanguageResourceService(),
            store: InMemoryCaptionStore(),
            languageStore: LanguageConfigurationStore(defaults: defaults),
            displayLocale: Locale(identifier: "zh-Hans")
        )

        await viewModel.loadLanguages()

        XCTAssertNil(viewModel.currentConfiguration)
        XCTAssertFalse(viewModel.canStartBroadcast)
        XCTAssertTrue(viewModel.errorMessage?.contains("重新选择") == true)
    }

    func testNoLongerCataloguedSavedConfigurationDisablesBroadcast() async {
        let unavailable = LanguagePairConfiguration(
            sourceSpeechLocaleIdentifier: "en-US",
            sourceTranslationLanguageIdentifier: "en",
            targetTranslationLanguageIdentifier: "zh-Hans"
        )
        let viewModel = AppViewModel(
            catalogService: FixedLanguageCatalogService(snapshot: LanguageTestFixture.catalog),
            resourceService: RecordingLanguageResourceService(),
            store: InMemoryCaptionStore(),
            languageStore: InMemoryLanguageConfigurationStore(value: unavailable),
            displayLocale: Locale(identifier: "zh-Hans")
        )

        await viewModel.loadLanguages()

        XCTAssertNil(viewModel.currentConfiguration)
        XCTAssertFalse(viewModel.canStartBroadcast)
        XCTAssertTrue(viewModel.errorMessage?.contains("重新选择") == true)
    }

    func testMissingConfigurationDefaultsAndPersistsFirstRunSelection() async {
        let resources = RecordingLanguageResourceService()
        await resources.setState(
            .init(
                speech: .init(status: .installed, isReserved: true),
                translation: .installed
            ),
            for: LanguageTestFixture.pair
        )
        let languageStore = InMemoryLanguageConfigurationStore()
        let viewModel = AppViewModel(
            catalogService: FixedLanguageCatalogService(snapshot: LanguageTestFixture.catalog),
            resourceService: resources,
            store: InMemoryCaptionStore(),
            languageStore: languageStore,
            displayLocale: Locale(identifier: "zh-Hans")
        )

        await viewModel.loadLanguages()

        XCTAssertEqual(viewModel.currentConfiguration, LanguageTestFixture.pair)
        XCTAssertEqual(languageStore.load(), LanguageTestFixture.pair)
        XCTAssertTrue(viewModel.canStartBroadcast)
    }

    func testTargetFallbackPrefersCurrentSystemLanguageWhenChineseIsUnavailable() async {
        let french = TranslationLanguageOption(
            languageIdentifier: "fr",
            displayName: "français"
        )
        let catalog = LanguageCatalogSnapshot(
            inputLanguages: [LanguageTestFixture.input],
            outputLanguages: [LanguageTestFixture.output, french]
        )
        let viewModel = AppViewModel(
            catalogService: FixedLanguageCatalogService(snapshot: catalog),
            resourceService: RecordingLanguageResourceService(),
            store: InMemoryCaptionStore(),
            languageStore: InMemoryLanguageConfigurationStore(),
            displayLocale: Locale(identifier: "fr-FR")
        )

        await viewModel.loadLanguages()

        XCTAssertEqual(viewModel.selectedOutput, french)
    }

    func testNewBroadcastSessionReplacesCachedHigherRevisionAfterCorruptStoreRecovery() async throws {
        let defaults = isolatedDefaults()
        let store = CaptionStore(defaults: defaults)
        let oldSnapshot = CaptionSnapshot(
            revision: 10_000,
            sourceText: "old",
            translatedText: "旧字幕",
            phase: .stopped,
            errorMessage: nil,
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        try store.save(oldSnapshot)
        let viewModel = AppViewModel(
            catalogService: FixedLanguageCatalogService(snapshot: LanguageTestFixture.catalog),
            resourceService: RecordingLanguageResourceService(),
            store: store,
            languageStore: InMemoryLanguageConfigurationStore(value: LanguageTestFixture.pair),
            displayLocale: Locale(identifier: "zh-Hans")
        )
        viewModel.refreshCaption()
        defaults.set(Data([0xFF, 0xAA]), forKey: "caption.snapshot")

        try BroadcastCaptionCoordinator(store: store).begin()
        viewModel.refreshCaption()

        XCTAssertEqual(viewModel.latestSnapshot?.phase, .broadcasting)
        XCTAssertEqual(viewModel.latestSnapshot?.sourceText, "")
        XCTAssertNotEqual(viewModel.latestSnapshot, oldSnapshot)
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

    private func isolatedDefaults() -> UserDefaults {
        let suiteName = "AppViewModelTests.\(UUID().uuidString)"
        addTeardownBlock {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }
        return UserDefaults(suiteName: suiteName)!
    }
}

private final class RecoveringCaptionStore: CaptionStoreProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private let snapshot: CaptionSnapshot
    private var shouldFail = true

    init(snapshot: CaptionSnapshot) {
        self.snapshot = snapshot
    }

    func load() throws -> CaptionSnapshot? {
        try lock.withLock {
            if shouldFail {
                shouldFail = false
                throw RecoveringCaptionStoreError.firstReadFailed
            }
            return snapshot
        }
    }

    func save(_ snapshot: CaptionSnapshot) throws {}

    func clear() throws {}
}

private enum RecoveringCaptionStoreError: LocalizedError {
    case firstReadFailed

    var errorDescription: String? {
        "模拟首次读取失败"
    }
}
