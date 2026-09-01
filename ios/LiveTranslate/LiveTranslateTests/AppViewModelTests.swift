import XCTest
@testable import LiveTranslate

@MainActor
final class AppViewModelTests: XCTestCase {
    func testBroadcastRequiresInstalledSpeechModel() async {
        let service = FakeModelPreparationService(status: .needsDownload)
        let viewModel = AppViewModel(modelService: service, store: InMemoryCaptionStore())

        viewModel.markTranslationReady()
        await viewModel.refreshModelStatus()

        XCTAssertFalse(viewModel.canStartBroadcast)
    }

    func testBroadcastRequiresPreparedTranslation() async {
        let service = FakeModelPreparationService(status: .installed)
        let viewModel = AppViewModel(modelService: service, store: InMemoryCaptionStore())

        await viewModel.refreshModelStatus()

        XCTAssertFalse(viewModel.canStartBroadcast)
    }

    func testBroadcastCanStartWhenBothModelsArePrepared() async {
        let service = FakeModelPreparationService(status: .installed)
        let viewModel = AppViewModel(modelService: service, store: InMemoryCaptionStore())

        viewModel.markTranslationReady()
        await viewModel.refreshModelStatus()

        XCTAssertTrue(viewModel.canStartBroadcast)
    }
}
