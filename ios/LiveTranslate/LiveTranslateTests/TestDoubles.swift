import Foundation
@testable import LiveTranslate

final class InMemoryCaptionStore: CaptionStoreProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: CaptionSnapshot?

    func load() throws -> CaptionSnapshot? {
        lock.withLock { snapshot }
    }

    func save(_ snapshot: CaptionSnapshot) throws {
        lock.withLock { self.snapshot = snapshot }
    }

    func clear() throws {
        lock.withLock { snapshot = nil }
    }
}

struct FixedLanguageCatalogService: LanguageCatalogProviding {
    let snapshot: LanguageCatalogSnapshot

    func load(displayLocale: Locale) async throws -> LanguageCatalogSnapshot {
        snapshot
    }
}

struct FailingLanguageCatalogService: LanguageCatalogProviding {
    let error: any Error

    func load(displayLocale: Locale) async throws -> LanguageCatalogSnapshot {
        throw error
    }
}

final class InMemoryLanguageConfigurationStore: LanguageConfigurationStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var result: LanguageConfigurationLoadResult

    init(value: LanguagePairConfiguration? = nil) {
        result = value.map(LanguageConfigurationLoadResult.configuration) ?? .missing
    }

    init(result: LanguageConfigurationLoadResult) {
        self.result = result
    }

    func loadResult() -> LanguageConfigurationLoadResult {
        lock.withLock { result }
    }

    func save(_ configuration: LanguagePairConfiguration) {
        lock.withLock { result = .configuration(configuration) }
    }
}

actor RecordingLanguageResourceService: LanguageResourceManaging {
    private var states: [LanguagePairConfiguration: LanguagePairResourceState] = [:]
    private(set) var preparedSpeechLocales: [String] = []
    private(set) var releasedSpeechLocales: [String] = []
    var reservedLocales: [String] = []

    func setState(_ state: LanguagePairResourceState, for pair: LanguagePairConfiguration) {
        states[pair] = state
    }

    func setReservedLocales(_ identifiers: [String]) {
        reservedLocales = identifiers
    }

    func status(for pair: LanguagePairConfiguration) async -> LanguagePairResourceState {
        states[pair] ?? .init(
            speech: .init(status: .unknown, isReserved: false),
            translation: .unknown
        )
    }

    func prepareSpeech(localeIdentifier: String) async throws {
        preparedSpeechLocales.append(localeIdentifier)
        for pair in Array(states.keys) where pair.sourceSpeechLocaleIdentifier == localeIdentifier {
            guard let current = states[pair] else { continue }
            states[pair] = .init(
                speech: .init(status: .installed, isReserved: true),
                translation: current.translation
            )
        }
    }

    func reservedSpeechLocaleIdentifiers() async -> [String] {
        reservedLocales
    }

    func releaseSpeech(localeIdentifier: String) async -> Bool {
        releasedSpeechLocales.append(localeIdentifier)
        reservedLocales.removeAll { $0 == localeIdentifier }
        for pair in Array(states.keys) where pair.sourceSpeechLocaleIdentifier == localeIdentifier {
            guard let current = states[pair] else { continue }
            states[pair] = .init(
                speech: .init(status: current.speech.status, isReserved: false),
                translation: current.translation
            )
        }
        return true
    }
}

actor ControlledLanguageResourceService: LanguageResourceManaging {
    private var statusContinuations: [(
        LanguagePairConfiguration,
        CheckedContinuation<LanguagePairResourceState, Never>
    )] = []
    private var statusRequestContinuations: [(
        LanguagePairConfiguration,
        CheckedContinuation<Void, Never>
    )] = []
    private var preparationContinuations: [(
        LanguagePairConfiguration,
        CheckedContinuation<Void, Error>
    )] = []
    private var preparationRequestContinuations: [(
        LanguagePairConfiguration,
        CheckedContinuation<Void, Never>
    )] = []
    private var latestPairBySpeechLocale: [String: LanguagePairConfiguration] = [:]

    func status(for pair: LanguagePairConfiguration) async -> LanguagePairResourceState {
        latestPairBySpeechLocale[pair.sourceSpeechLocaleIdentifier] = pair
        if let index = statusRequestContinuations.firstIndex(where: { $0.0 == pair }) {
            statusRequestContinuations.remove(at: index).1.resume()
        }
        return await withCheckedContinuation { continuation in
            statusContinuations.append((pair, continuation))
        }
    }

    func prepareSpeech(localeIdentifier: String) async throws {
        guard let pair = latestPairBySpeechLocale[localeIdentifier] else {
            throw ModelPreparationTestError.missingStatusRequest
        }
        if let index = preparationRequestContinuations.firstIndex(where: { $0.0 == pair }) {
            preparationRequestContinuations.remove(at: index).1.resume()
        }
        try await withCheckedThrowingContinuation { continuation in
            preparationContinuations.append((pair, continuation))
        }
    }

    func reservedSpeechLocaleIdentifiers() async -> [String] {
        []
    }

    func releaseSpeech(localeIdentifier: String) async -> Bool {
        true
    }

    func waitForStatusRequest(for pair: LanguagePairConfiguration) async {
        if statusContinuations.contains(where: { $0.0 == pair }) {
            return
        }
        await withCheckedContinuation { continuation in
            statusRequestContinuations.append((pair, continuation))
        }
    }

    func resolveStatus(
        for pair: LanguagePairConfiguration,
        with state: LanguagePairResourceState
    ) {
        guard let index = statusContinuations.firstIndex(where: { $0.0 == pair }) else {
            return
        }
        statusContinuations.remove(at: index).1.resume(returning: state)
    }

    func waitForPreparationRequest(for pair: LanguagePairConfiguration) async {
        if preparationContinuations.contains(where: { $0.0 == pair }) {
            return
        }
        await withCheckedContinuation { continuation in
            preparationRequestContinuations.append((pair, continuation))
        }
    }

    func failPreparation(for pair: LanguagePairConfiguration) {
        guard let index = preparationContinuations.firstIndex(where: { $0.0 == pair }) else {
            return
        }
        preparationContinuations.remove(at: index).1.resume(
            throwing: ModelPreparationTestError.installationFailed
        )
    }
}

enum LanguageTestFixture {
    static let input = SpeechLanguageOption(
        localeIdentifier: "fr-FR",
        translationLanguageIdentifier: "fr",
        displayName: "法语（法国）"
    )
    static let output = TranslationLanguageOption(
        languageIdentifier: "de",
        displayName: "德语"
    )
    static let pair = LanguagePairConfiguration(
        sourceSpeechLocaleIdentifier: "fr-FR",
        sourceTranslationLanguageIdentifier: "fr",
        targetTranslationLanguageIdentifier: "de"
    )
    static let catalog = LanguageCatalogSnapshot(
        inputLanguages: [input],
        outputLanguages: [output]
    )
}

enum ModelPreparationTestError: LocalizedError, Sendable {
    case installationFailed
    case missingStatusRequest
    case catalogFailed

    var errorDescription: String? {
        switch self {
        case .installationFailed:
            "模拟安装失败"
        case .missingStatusRequest:
            "缺少模型状态请求"
        case .catalogFailed:
            "模拟目录加载失败"
        }
    }
}
