import XCTest
@testable import LiveTranslate

final class BroadcastStartupValidationTests: XCTestCase {
    func testPassThroughValidatesOnlyArbitrarySpeechLocaleAndDoesNotBuildTranslationClient() async throws {
        let pair = LanguagePairConfiguration(
            sourceSpeechLocaleIdentifier: "sr-Latn-RS",
            sourceTranslationLanguageIdentifier: "sr-Latn",
            targetTranslationLanguageIdentifier: "sr-Latn"
        )
        let checker = RecordingBroadcastResourceChecker(
            speechStatus: .installed,
            translationStatus: .unsupported
        )
        let builder = RecordingTranslationClientBuilder()
        let preparer = BroadcastStartupPreparer(
            checker: checker,
            translationClientBuilder: builder
        )

        let resources = try await preparer.prepare(configuration: pair)
        let speechLocaleIdentifiers = await checker.speechLocaleIdentifiers
        let translationPairs = await checker.translationPairs
        let translatedText = try await resources.translator.translate("Здраво")

        XCTAssertEqual(resources.sourceSpeechLocaleIdentifier, "sr-Latn-RS")
        XCTAssertEqual(speechLocaleIdentifiers, ["sr-Latn-RS"])
        XCTAssertEqual(translationPairs, [])
        XCTAssertEqual(builder.configurations, [])
        XCTAssertEqual(translatedText, "Здраво")
    }

    func testInstalledSpeechAndTranslationBuildInstalledOnlyClientAfterBothChecks() async throws {
        let checker = RecordingBroadcastResourceChecker(
            speechStatus: .installed,
            translationStatus: .installed
        )
        let builder = RecordingTranslationClientBuilder()
        let preparer = BroadcastStartupPreparer(
            checker: checker,
            translationClientBuilder: builder
        )

        let resources = try await preparer.prepare(configuration: LanguageTestFixture.pair)
        let speechLocaleIdentifiers = await checker.speechLocaleIdentifiers
        let translationPairs = await checker.translationPairs

        XCTAssertEqual(resources.sourceSpeechLocaleIdentifier, "fr-FR")
        XCTAssertEqual(speechLocaleIdentifiers, ["fr-FR"])
        XCTAssertEqual(translationPairs, [.init(source: "fr", target: "de")])
        XCTAssertEqual(
            builder.configurations,
            [TranslationClientConfiguration(LanguageTestFixture.pair)]
        )
    }

    func testAvailableSpeechFailsBeforeTranslationCheckOrClientConstruction() async {
        let checker = RecordingBroadcastResourceChecker(
            speechStatus: .available,
            translationStatus: .installed
        )
        let builder = RecordingTranslationClientBuilder()
        let error = await capturedError(
            checker: checker,
            builder: builder
        )
        let translationPairs = await checker.translationPairs

        XCTAssertEqual(
            error as? BroadcastStartupValidationError,
            .speechResourcesNotInstalled(localeIdentifier: "fr-FR")
        )
        XCTAssertEqual(translationPairs, [])
        XCTAssertEqual(builder.configurations, [])
    }

    func testUnsupportedSpeechFailsBeforeTranslationCheckOrClientConstruction() async {
        let checker = RecordingBroadcastResourceChecker(
            speechStatus: .unsupported,
            translationStatus: .installed
        )
        let builder = RecordingTranslationClientBuilder()
        let error = await capturedError(
            checker: checker,
            builder: builder
        )
        let translationPairs = await checker.translationPairs

        XCTAssertEqual(
            error as? BroadcastStartupValidationError,
            .speechLocaleUnsupported(localeIdentifier: "fr-FR")
        )
        XCTAssertEqual(translationPairs, [])
        XCTAssertEqual(builder.configurations, [])
    }

    func testAvailableTranslationFailsWithoutClientConstruction() async {
        let checker = RecordingBroadcastResourceChecker(
            speechStatus: .installed,
            translationStatus: .available
        )
        let builder = RecordingTranslationClientBuilder()
        let error = await capturedError(
            checker: checker,
            builder: builder
        )

        XCTAssertEqual(
            error as? BroadcastStartupValidationError,
            .translationResourcesNotInstalled(source: "fr", target: "de")
        )
        XCTAssertEqual(builder.configurations, [])
    }

    func testUnsupportedTranslationFailsWithoutClientConstruction() async {
        let checker = RecordingBroadcastResourceChecker(
            speechStatus: .installed,
            translationStatus: .unsupported
        )
        let builder = RecordingTranslationClientBuilder()
        let error = await capturedError(
            checker: checker,
            builder: builder
        )

        XCTAssertEqual(
            error as? BroadcastStartupValidationError,
            .translationPairUnsupported(source: "fr", target: "de")
        )
        XCTAssertEqual(builder.configurations, [])
    }

    private func capturedError(
        checker: RecordingBroadcastResourceChecker,
        builder: RecordingTranslationClientBuilder
    ) async -> (any Error)? {
        do {
            _ = try await BroadcastStartupPreparer(
                checker: checker,
                translationClientBuilder: builder
            ).prepare(configuration: LanguageTestFixture.pair)
            return nil
        } catch {
            return error
        }
    }
}

private actor RecordingBroadcastResourceChecker: BroadcastInstalledResourceChecking {
    struct TranslationPair: Equatable {
        let source: String
        let target: String
    }

    let speechStatusValue: BroadcastInstalledResourceStatus
    let translationStatusValue: BroadcastInstalledResourceStatus
    private(set) var speechLocaleIdentifiers: [String] = []
    private(set) var translationPairs: [TranslationPair] = []

    init(
        speechStatus: BroadcastInstalledResourceStatus,
        translationStatus: BroadcastInstalledResourceStatus
    ) {
        speechStatusValue = speechStatus
        translationStatusValue = translationStatus
    }

    func speechStatus(
        localeIdentifier: String
    ) async -> BroadcastInstalledResourceStatus {
        speechLocaleIdentifiers.append(localeIdentifier)
        return speechStatusValue
    }

    func translationStatus(
        sourceIdentifier: String,
        targetIdentifier: String
    ) async -> BroadcastInstalledResourceStatus {
        translationPairs.append(.init(source: sourceIdentifier, target: targetIdentifier))
        return translationStatusValue
    }
}

private final class RecordingTranslationClientBuilder:
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
