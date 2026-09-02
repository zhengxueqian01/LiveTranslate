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

    func testReleasingUsesFreshBroadcastSnapshotBeforeObservationRefresh() async throws {
        let store = InMemoryCaptionStore()
        try store.save(.init(
            revision: 99,
            sourceText: "old",
            translatedText: "旧译文",
            phase: .stopped,
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
        try BroadcastCaptionCoordinator(store: store).begin()

        await viewModel.releaseSpeechLocale("fr-FR")

        XCTAssertEqual(try store.load()?.revision, 100)
        XCTAssertTrue(viewModel.canStartBroadcast)
    }

    func testSuccessfulReleaseClearsPreviousReleaseFailure() async {
        let resourceService = BlockingLanguageResourceService(
            state: .init(
                speech: .init(status: .installed, isReserved: true),
                translation: .installed
            ),
            releaseResults: [false, true]
        )
        let viewModel = AppViewModel(
            catalogService: FixedLanguageCatalogService(snapshot: LanguageTestFixture.catalog),
            resourceService: resourceService,
            store: InMemoryCaptionStore(),
            languageStore: InMemoryLanguageConfigurationStore(value: LanguageTestFixture.pair),
            displayLocale: Locale(identifier: "zh-Hans")
        )
        await viewModel.loadLanguages()

        await viewModel.releaseSpeechLocale("en-US")
        XCTAssertEqual(viewModel.errorMessage, "无法释放语音模型 en-US。")

        await viewModel.releaseSpeechLocale("en-US")
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertTrue(viewModel.canStartBroadcast)
    }

    func testFailureReleasingNonCurrentLocaleDoesNotBlockReadyPair() async {
        let resourceService = BlockingLanguageResourceService(
            state: .init(
                speech: .init(status: .installed, isReserved: true),
                translation: .installed
            ),
            releaseResults: [false]
        )
        let viewModel = AppViewModel(
            catalogService: FixedLanguageCatalogService(snapshot: LanguageTestFixture.catalog),
            resourceService: resourceService,
            store: InMemoryCaptionStore(),
            languageStore: InMemoryLanguageConfigurationStore(value: LanguageTestFixture.pair),
            displayLocale: Locale(identifier: "zh-Hans")
        )
        await viewModel.loadLanguages()

        await viewModel.releaseSpeechLocale("en-US")

        XCTAssertEqual(viewModel.errorMessage, "无法释放语音模型 en-US。")
        XCTAssertTrue(viewModel.canStartBroadcast)
    }

    func testBeginningPreparationIsBlockedWhileReleaseIsInFlight() async {
        let resourceService = BlockingLanguageResourceService(
            state: .init(
                speech: .init(status: .needsDownload, isReserved: false),
                translation: .installed
            ),
            blocksRelease: true
        )
        let viewModel = AppViewModel(
            catalogService: FixedLanguageCatalogService(snapshot: LanguageTestFixture.catalog),
            resourceService: resourceService,
            store: InMemoryCaptionStore(),
            languageStore: InMemoryLanguageConfigurationStore(value: LanguageTestFixture.pair),
            displayLocale: Locale(identifier: "zh-Hans")
        )
        await viewModel.loadLanguages()

        let release = Task { await viewModel.releaseSpeechLocale("fr-FR") }
        await resourceService.waitForReleaseRequest()
        let action = await viewModel.beginModelPreparation()
        let preparedSpeechLocales = await resourceService.preparedSpeechLocales

        XCTAssertEqual(action, .none)
        XCTAssertEqual(preparedSpeechLocales, [])

        await resourceService.finishRelease(with: true)
        await release.value
    }

    func testReleasingIsBlockedWhenSharedCaptionStoreCannotBeRead() async {
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
            store: FailingCaptionStore(),
            languageStore: InMemoryLanguageConfigurationStore(value: LanguageTestFixture.pair),
            displayLocale: Locale(identifier: "zh-Hans")
        )
        await viewModel.loadLanguages()

        await viewModel.releaseSpeechLocale("fr-FR")

        XCTAssertTrue(viewModel.canStartBroadcast)
    }
}

private struct FailingCaptionStore: CaptionStoreProtocol {
    func load() throws -> CaptionSnapshot? {
        throw CaptionStoreReadError.failed
    }

    func save(_ snapshot: CaptionSnapshot) throws {}

    func clear() throws {}
}

private enum CaptionStoreReadError: Error {
    case failed
}

actor BlockingLanguageResourceService: LanguageResourceManaging {
    private var state: LanguagePairResourceState
    private var releaseResults: [Bool]
    private let blocksRelease: Bool
    private var releaseContinuation: CheckedContinuation<Bool, Never>?
    private var releaseRequestContinuation: CheckedContinuation<Void, Never>?
    private(set) var preparedSpeechLocales: [String] = []

    init(
        state: LanguagePairResourceState,
        releaseResults: [Bool] = [],
        blocksRelease: Bool = false
    ) {
        self.state = state
        self.releaseResults = releaseResults
        self.blocksRelease = blocksRelease
    }

    func status(for configuration: LanguagePairConfiguration) async -> LanguagePairResourceState {
        state
    }

    func prepareSpeech(localeIdentifier: String) async throws {
        preparedSpeechLocales.append(localeIdentifier)
        state = .init(
            speech: .init(status: .installed, isReserved: true),
            translation: state.translation
        )
    }

    func reservedSpeechLocaleIdentifiers() async -> [String] {
        []
    }

    func releaseSpeech(localeIdentifier: String) async -> Bool {
        if blocksRelease {
            releaseRequestContinuation?.resume()
            return await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        }
        return releaseResults.isEmpty ? true : releaseResults.removeFirst()
    }

    func waitForReleaseRequest() async {
        if releaseContinuation != nil {
            return
        }
        await withCheckedContinuation { continuation in
            releaseRequestContinuation = continuation
        }
    }

    func finishRelease(with result: Bool) {
        releaseContinuation?.resume(returning: result)
        releaseContinuation = nil
    }
}
