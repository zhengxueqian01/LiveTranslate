import Foundation
import XCTest
@testable import LiveTranslate

final class BroadcastStartupOrchestratorTests: XCTestCase {
    func testDoesNotBeginOrAcceptAudioBeforeSpeechValidationSucceeds() async throws {
        let checker = SuspendingStartupResourceChecker(translationStatus: .installed)
        let translationBuilder = StartupRecordingTranslationClientBuilder()
        let recorder = StartupOrchestrationRecorder()
        let orchestrator = makeOrchestrator(
            checker: checker,
            translationBuilder: translationBuilder,
            recorder: recorder
        )

        let startup = Task {
            try await orchestrator.start(
                configuration: LanguageTestFixture.pair,
                acceptAudio: recorder.acceptAudio
            )
        }
        await checker.waitForSpeechRequest()

        XCTAssertFalse(recorder.didBegin)
        XCTAssertEqual(recorder.acceptedSpeechLocaleIdentifiers, [])

        await checker.resolveSpeechStatus(.installed)
        _ = try await startup.value

        XCTAssertTrue(recorder.didBegin)
        XCTAssertEqual(recorder.acceptedSpeechLocaleIdentifiers, ["fr-FR"])
    }

    func testSpeechValidationFailureDoesNotBeginOrAcceptAudio() async {
        let checker = StaticStartupResourceChecker(
            speechStatus: .available,
            translationStatus: .installed
        )
        let recorder = StartupOrchestrationRecorder()
        let error = await startError(
            checker: checker,
            translationBuilder: StartupRecordingTranslationClientBuilder(),
            recorder: recorder,
            configuration: LanguageTestFixture.pair
        )

        XCTAssertEqual(
            error as? BroadcastStartupValidationError,
            .speechResourcesNotInstalled(localeIdentifier: "fr-FR")
        )
        XCTAssertFalse(recorder.didBegin)
        XCTAssertEqual(recorder.acceptedSpeechLocaleIdentifiers, [])
    }

    func testTranslationValidationFailureDoesNotBeginOrAcceptAudio() async {
        let checker = StaticStartupResourceChecker(
            speechStatus: .installed,
            translationStatus: .available
        )
        let recorder = StartupOrchestrationRecorder()
        let error = await startError(
            checker: checker,
            translationBuilder: StartupRecordingTranslationClientBuilder(),
            recorder: recorder,
            configuration: LanguageTestFixture.pair
        )

        XCTAssertEqual(
            error as? BroadcastStartupValidationError,
            .translationResourcesNotInstalled(source: "fr", target: "de")
        )
        XCTAssertFalse(recorder.didBegin)
        XCTAssertEqual(recorder.acceptedSpeechLocaleIdentifiers, [])
    }

    func testPassThroughDoesNotConstructTranslationClient() async throws {
        let pair = LanguagePairConfiguration(
            sourceSpeechLocaleIdentifier: "fr-FR",
            sourceTranslationLanguageIdentifier: "fr",
            targetTranslationLanguageIdentifier: "fr"
        )
        let translationBuilder = StartupRecordingTranslationClientBuilder()
        let recorder = StartupOrchestrationRecorder()
        let orchestrator = makeOrchestrator(
            checker: StaticStartupResourceChecker(
                speechStatus: .installed,
                translationStatus: .unsupported
            ),
            translationBuilder: translationBuilder,
            recorder: recorder
        )

        _ = try await orchestrator.start(
            configuration: pair,
            acceptAudio: recorder.acceptAudio
        )

        XCTAssertEqual(translationBuilder.configurations, [])
        XCTAssertEqual(recorder.constructedSpeechLocaleIdentifiers, ["fr-FR"])
        XCTAssertEqual(recorder.acceptedSpeechLocaleIdentifiers, ["fr-FR"])
    }

    func testForwardsArbitrarySpeechLocaleToCoordinatorAndAudioAcceptance() async throws {
        let pair = LanguagePairConfiguration(
            sourceSpeechLocaleIdentifier: "fr-FR",
            sourceTranslationLanguageIdentifier: "fr",
            targetTranslationLanguageIdentifier: "de"
        )
        let recorder = StartupOrchestrationRecorder()
        let orchestrator = makeOrchestrator(
            checker: StaticStartupResourceChecker(
                speechStatus: .installed,
                translationStatus: .installed
            ),
            translationBuilder: StartupRecordingTranslationClientBuilder(),
            recorder: recorder
        )

        _ = try await orchestrator.start(
            configuration: pair,
            acceptAudio: recorder.acceptAudio
        )

        XCTAssertEqual(recorder.constructedSpeechLocaleIdentifiers, ["fr-FR"])
        XCTAssertEqual(recorder.acceptedSpeechLocaleIdentifiers, ["fr-FR"])
    }

    private func makeOrchestrator(
        checker: any BroadcastInstalledResourceChecking,
        translationBuilder: any BroadcastTranslationClientBuilding,
        recorder: StartupOrchestrationRecorder
    ) -> BroadcastStartupOrchestrator {
        BroadcastStartupOrchestrator(
            preparer: .init(
                checker: checker,
                translationClientBuilder: translationBuilder
            ),
            makeCoordinator: recorder.makeCoordinator
        )
    }

    private func startError(
        checker: any BroadcastInstalledResourceChecking,
        translationBuilder: any BroadcastTranslationClientBuilding,
        recorder: StartupOrchestrationRecorder,
        configuration: LanguagePairConfiguration
    ) async -> (any Error)? {
        do {
            _ = try await makeOrchestrator(
                checker: checker,
                translationBuilder: translationBuilder,
                recorder: recorder
            ).start(configuration: configuration, acceptAudio: recorder.acceptAudio)
            return nil
        } catch {
            return error
        }
    }
}

private actor SuspendingStartupResourceChecker: BroadcastInstalledResourceChecking {
    private let translationStatusValue: BroadcastInstalledResourceStatus
    private var speechRequestContinuation: CheckedContinuation<Void, Never>?
    private var speechStatusContinuation: CheckedContinuation<BroadcastInstalledResourceStatus, Never>?

    init(translationStatus: BroadcastInstalledResourceStatus) {
        translationStatusValue = translationStatus
    }

    func speechStatus(localeIdentifier: String) async -> BroadcastInstalledResourceStatus {
        speechRequestContinuation?.resume()
        speechRequestContinuation = nil
        return await withCheckedContinuation { continuation in
            speechStatusContinuation = continuation
        }
    }

    func translationStatus(
        sourceIdentifier: String,
        targetIdentifier: String
    ) async -> BroadcastInstalledResourceStatus {
        translationStatusValue
    }

    func waitForSpeechRequest() async {
        if speechStatusContinuation != nil {
            return
        }
        await withCheckedContinuation { continuation in
            speechRequestContinuation = continuation
        }
    }

    func resolveSpeechStatus(_ status: BroadcastInstalledResourceStatus) {
        speechStatusContinuation?.resume(returning: status)
        speechStatusContinuation = nil
    }
}

private actor StaticStartupResourceChecker: BroadcastInstalledResourceChecking {
    private let speechStatusValue: BroadcastInstalledResourceStatus
    private let translationStatusValue: BroadcastInstalledResourceStatus

    init(
        speechStatus: BroadcastInstalledResourceStatus,
        translationStatus: BroadcastInstalledResourceStatus
    ) {
        speechStatusValue = speechStatus
        translationStatusValue = translationStatus
    }

    func speechStatus(localeIdentifier: String) async -> BroadcastInstalledResourceStatus {
        speechStatusValue
    }

    func translationStatus(
        sourceIdentifier: String,
        targetIdentifier: String
    ) async -> BroadcastInstalledResourceStatus {
        translationStatusValue
    }
}

private final class StartupRecordingTranslationClientBuilder:
    BroadcastTranslationClientBuilding,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var recordedConfigurations: [TranslationClientConfiguration] = []

    var configurations: [TranslationClientConfiguration] {
        lock.withLock { recordedConfigurations }
    }

    func makeTranslationClient(
        configuration: TranslationClientConfiguration
    ) -> any CaptionTranslating {
        lock.withLock { recordedConfigurations.append(configuration) }
        return PassThroughTranslationClient()
    }
}

private final class StartupOrchestrationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let store = InMemoryCaptionStore()
    private var recordedConstructedSpeechLocaleIdentifiers: [String] = []
    private var recordedAcceptedSpeechLocaleIdentifiers: [String] = []

    var didBegin: Bool {
        (try? store.load())?.phase == .broadcasting
    }

    var constructedSpeechLocaleIdentifiers: [String] {
        lock.withLock { recordedConstructedSpeechLocaleIdentifiers }
    }

    var acceptedSpeechLocaleIdentifiers: [String] {
        lock.withLock { recordedAcceptedSpeechLocaleIdentifiers }
    }

    func makeCoordinator(
        sourceSpeechLocaleIdentifier: String,
        translator: any CaptionTranslating
    ) -> BroadcastCaptionCoordinator {
        lock.withLock {
            recordedConstructedSpeechLocaleIdentifiers.append(sourceSpeechLocaleIdentifier)
        }
        return BroadcastCaptionCoordinator(translator: translator, store: store)
    }

    func acceptAudio(_ session: BroadcastStartupSession) {
        lock.withLock {
            recordedAcceptedSpeechLocaleIdentifiers.append(
                session.sourceSpeechLocaleIdentifier
            )
        }
    }
}
