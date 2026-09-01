import XCTest
@testable import LiveTranslate

@MainActor
final class AppViewModelTests: XCTestCase {
    func testCaptionObservationRefreshesSharedStoreAfterPollingInterval() async throws {
        let store = InMemoryCaptionStore()
        let viewModel = AppViewModel(
            modelService: FakeModelPreparationService(status: .installed),
            store: store,
            languageStore: SourceLanguageStore(defaults: .standard)
        )
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
        let viewModel = AppViewModel(
            modelService: FakeModelPreparationService(status: .installed),
            store: store,
            languageStore: SourceLanguageStore(defaults: .standard)
        )
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

    func testOldLanguageInstallationFailureDoesNotOverwriteCurrentSpeechStatus() async {
        let service = ControlledModelPreparationService()
        let viewModel = AppViewModel(
            modelService: service,
            store: InMemoryCaptionStore(),
            languageStore: SourceLanguageStore(defaults: .standard)
        )
        viewModel.selectedLanguage = .english
        let installation = Task { await viewModel.installSpeechModel() }
        await service.waitForInstallationRequest(for: .english)

        viewModel.selectedLanguage = .japanese
        let japaneseStatus = Task { await viewModel.refreshModelStatus() }
        await service.waitForStatusRequest(for: .japanese)
        await service.resolveStatus(for: .japanese, with: .installed)
        await japaneseStatus.value
        await service.failInstallation(for: .english)
        await installation.value

        XCTAssertEqual(viewModel.speechStatus, .installed)
    }

    func testLateSpeechStatusForOldLanguageDoesNotOverwriteCurrentLanguage() async {
        let service = ControlledModelPreparationService()
        let viewModel = AppViewModel(
            modelService: service,
            store: InMemoryCaptionStore(),
            languageStore: SourceLanguageStore(defaults: .standard)
        )
        viewModel.selectedLanguage = .english
        let englishRequest = Task { await viewModel.refreshModelStatus() }
        await service.waitForStatusRequest(for: .english)

        viewModel.selectedLanguage = .japanese
        let japaneseRequest = Task { await viewModel.refreshModelStatus() }
        await service.waitForStatusRequest(for: .japanese)
        await service.resolveStatus(for: .japanese, with: .installed)
        await japaneseRequest.value
        await service.resolveStatus(for: .english, with: .needsDownload)
        await englishRequest.value

        XCTAssertEqual(viewModel.speechStatus, .installed)
    }

    func testOldTranslationCompletionDoesNotReadyNewlySelectedLanguage() {
        let viewModel = AppViewModel(
            modelService: FakeModelPreparationService(status: .installed),
            store: InMemoryCaptionStore(),
            languageStore: SourceLanguageStore(defaults: .standard)
        )
        viewModel.selectedLanguage = .japanese
        viewModel.markTranslationNeedsPreparation()

        viewModel.markTranslationReady(for: .english)

        XCTAssertFalse(viewModel.isTranslationReady)

        viewModel.markTranslationReady(for: .japanese)

        XCTAssertTrue(viewModel.isTranslationReady)
    }

    func testTranslationReadyDoesNotClearCaptionStoreFailure() async {
        let viewModel = AppViewModel(
            modelService: FakeModelPreparationService(status: .installed),
            store: nil,
            languageStore: SourceLanguageStore(defaults: .standard)
        )

        await viewModel.refreshModelStatus()
        viewModel.markTranslationReady()

        XCTAssertFalse(viewModel.canStartBroadcast)
        XCTAssertEqual(
            viewModel.errorMessage,
            "无法打开 App Group，请检查两个 Target 的签名与 App Group 配置。"
        )
    }

    func testChangingSelectedLanguagePersistsToSharedConfiguration() {
        let suiteName = "AppViewModelLanguageTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let languageStore = SourceLanguageStore(defaults: defaults)
        let viewModel = AppViewModel(
            modelService: FakeModelPreparationService(status: .installed),
            store: InMemoryCaptionStore(),
            languageStore: languageStore
        )

        viewModel.selectedLanguage = .japanese

        XCTAssertEqual(defaults.string(forKey: SourceLanguageStore.key), "ja-JP")
        XCTAssertEqual(languageStore.load(), .japanese)
    }

    func testBroadcastRequiresInstalledSpeechModel() async {
        let service = FakeModelPreparationService(status: .needsDownload)
        let viewModel = AppViewModel(
            modelService: service,
            store: InMemoryCaptionStore(),
            languageStore: SourceLanguageStore(defaults: .standard)
        )

        viewModel.markTranslationReady()
        await viewModel.refreshModelStatus()

        XCTAssertFalse(viewModel.canStartBroadcast)
    }

    func testBroadcastRequiresPreparedTranslation() async {
        let service = FakeModelPreparationService(status: .installed)
        let viewModel = AppViewModel(
            modelService: service,
            store: InMemoryCaptionStore(),
            languageStore: SourceLanguageStore(defaults: .standard)
        )

        await viewModel.refreshModelStatus()

        XCTAssertFalse(viewModel.canStartBroadcast)
    }

    func testBroadcastCanStartWhenBothModelsArePrepared() async {
        let service = FakeModelPreparationService(status: .installed)
        let viewModel = AppViewModel(
            modelService: service,
            store: InMemoryCaptionStore(),
            languageStore: SourceLanguageStore(defaults: .standard)
        )

        viewModel.markTranslationReady()
        await viewModel.refreshModelStatus()

        XCTAssertTrue(viewModel.canStartBroadcast)
    }
}
