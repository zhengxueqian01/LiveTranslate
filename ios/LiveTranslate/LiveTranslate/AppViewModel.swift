import Combine
import Foundation
import SwiftUI

protocol ModelPreparing: Sendable {
    func speechStatus(for source: SourceLanguage) async -> ModelResourceStatus
    func installSpeechModel(for source: SourceLanguage) async throws
}

enum ModelPreparationAction: Equatable, Sendable {
    case none
    case prepareTranslation(TranslationPreparationRequest)
}

struct TranslationPreparationRequest: Equatable, Sendable {
    let configuration: LanguagePairConfiguration
    let token: UInt64
}

enum ModelPreparationPhase: Equatable, Sendable {
    case idle
    case preparingSpeech
    case preparingTranslation
}

@MainActor
final class AppViewModel: ObservableObject {
    @Published private(set) var inputLanguages: [SpeechLanguageOption] = []
    @Published private(set) var outputLanguages: [TranslationLanguageOption] = []
    @Published var selectedInput: SpeechLanguageOption?
    @Published var selectedOutput: TranslationLanguageOption?
    @Published private(set) var resourceState = LanguagePairResourceState(
        speech: .init(status: .unknown, isReserved: false),
        translation: .unknown
    )
    @Published private(set) var preparationPhase: ModelPreparationPhase = .idle
    @Published private(set) var latestSnapshot: CaptionSnapshot?
    @Published private(set) var reservedSpeechLocaleIdentifiers: [String] = []
    @Published private(set) var languageCatalogErrorMessage: String?
    @Published private(set) var errorMessage: String?

    private let catalogService: any LanguageCatalogProviding
    private let resourceService: any LanguageResourceManaging
    private let store: (any CaptionStoreProtocol)?
    private let languageStore: any LanguageConfigurationStoring
    private let displayLocale: Locale
    private let storageErrorMessage: String?
    private var modelErrorMessage: String?
    private var captionErrorMessage: String?
    private var captionObservationTask: Task<Void, Never>?
    private var requestGeneration: UInt64 = 0
    private var selectionGeneration: UInt64 = 0
    private var translationPreparationGeneration: UInt64 = 0
    private var activeTranslationPreparation: TranslationPreparationRequest?

    var currentConfiguration: LanguagePairConfiguration? {
        guard let selectedInput, let selectedOutput else { return nil }
        return .init(
            sourceSpeechLocaleIdentifier: selectedInput.localeIdentifier,
            sourceTranslationLanguageIdentifier: selectedInput.translationLanguageIdentifier,
            targetTranslationLanguageIdentifier: selectedOutput.languageIdentifier
        )
    }

    var canStartBroadcast: Bool {
        store != nil && resourceState.isReady && errorMessage == nil
    }

    var canReleaseSpeechModels: Bool {
        preparationPhase == .idle && !isBroadcastActive
    }

    init(
        catalogService: any LanguageCatalogProviding,
        resourceService: any LanguageResourceManaging,
        store: (any CaptionStoreProtocol)?,
        languageStore: any LanguageConfigurationStoring,
        displayLocale: Locale = .current
    ) {
        self.catalogService = catalogService
        self.resourceService = resourceService
        self.store = store
        self.languageStore = languageStore
        self.displayLocale = displayLocale
        storageErrorMessage = store == nil
            ? "无法打开 App Group，请检查两个 Target 的签名与 App Group 配置。"
            : nil
        modelErrorMessage = nil
        captionErrorMessage = nil
        captionObservationTask = nil
        languageCatalogErrorMessage = nil
        errorMessage = storageErrorMessage
    }

    static func live() -> AppViewModel {
        guard let defaults = UserDefaults(suiteName: CaptionStore.appGroupIdentifier) else {
            return AppViewModel(
                catalogService: SystemLanguageCatalogService(),
                resourceService: SystemLanguageResourceService(),
                store: nil,
                languageStore: UnavailableLanguageConfigurationStore()
            )
        }
        return AppViewModel(
            catalogService: SystemLanguageCatalogService(),
            resourceService: SystemLanguageResourceService(),
            store: CaptionStore(defaults: defaults),
            languageStore: LanguageConfigurationStore(defaults: defaults)
        )
    }

    func loadLanguages() async {
        selectionGeneration &+= 1
        let generation = nextRequestGeneration()
        inputLanguages = []
        outputLanguages = []
        selectedInput = nil
        selectedOutput = nil
        resourceState = Self.unknownResourceState
        preparationPhase = .idle
        activeTranslationPreparation = nil
        languageCatalogErrorMessage = nil
        modelErrorMessage = nil
        refreshErrorMessage()

        do {
            let snapshot = try await catalogService.load(displayLocale: displayLocale)
            guard generation == requestGeneration else { return }
            guard !snapshot.inputLanguages.isEmpty, !snapshot.outputLanguages.isEmpty else {
                throw LanguageCatalogLoadError.emptyCatalog
            }

            inputLanguages = snapshot.inputLanguages
            outputLanguages = snapshot.outputLanguages
            let resolved = resolveSelection(
                saved: languageStore.load(),
                snapshot: snapshot
            )
            selectedInput = resolved.input
            selectedOutput = resolved.output
            persistCurrentConfiguration()
            await refreshResourceStatus()
        } catch {
            guard generation == requestGeneration else { return }
            inputLanguages = []
            outputLanguages = []
            selectedInput = nil
            selectedOutput = nil
            resourceState = Self.unknownResourceState
            preparationPhase = .idle
            languageCatalogErrorMessage = "语言列表加载失败：\(error.localizedDescription)"
            refreshErrorMessage()
        }
    }

    func selectInput(identifier: String) async {
        guard let option = inputLanguages.first(where: { $0.localeIdentifier == identifier }) else {
            return
        }
        selectedInput = option
        selectionDidChange()
        persistCurrentConfiguration()
        await refreshResourceStatus()
    }

    func selectOutput(identifier: String) async {
        guard let option = outputLanguages.first(where: { $0.languageIdentifier == identifier }) else {
            return
        }
        selectedOutput = option
        selectionDidChange()
        persistCurrentConfiguration()
        await refreshResourceStatus()
    }

    func refreshResourceStatus() async {
        guard let request = currentConfiguration else {
            resourceState = Self.unknownResourceState
            return
        }
        let generation = nextRequestGeneration()
        resourceState = Self.unknownResourceState
        let state = await resourceService.status(for: request)
        guard generation == requestGeneration, request == currentConfiguration else {
            return
        }
        resourceState = state
    }

    func loadReservedSpeechLocales() async {
        reservedSpeechLocaleIdentifiers = await resourceService.reservedSpeechLocaleIdentifiers()
    }

    func releaseSpeechLocale(_ identifier: String) async {
        guard canReleaseSpeechModels else { return }
        guard await resourceService.releaseSpeech(localeIdentifier: identifier) else {
            modelErrorMessage = "无法释放语音模型 \(identifier)。"
            refreshErrorMessage()
            return
        }
        await loadReservedSpeechLocales()
        if currentConfiguration?.sourceSpeechLocaleIdentifier == identifier {
            await refreshResourceStatus()
        }
    }

    func beginModelPreparation() async -> ModelPreparationAction {
        guard preparationPhase == .idle,
              let request = currentConfiguration,
              resourceState.speech.status != .unknown,
              resourceState.speech.status != .unsupported,
              resourceState.translation != .unknown,
              resourceState.translation != .unsupported else {
            return .none
        }
        let generation = selectionGeneration
        preparationPhase = .preparingSpeech
        modelErrorMessage = nil
        refreshErrorMessage()
        do {
            if !resourceState.speech.isReady {
                try await resourceService.prepareSpeech(
                    localeIdentifier: request.sourceSpeechLocaleIdentifier
                )
            }
            guard generation == selectionGeneration, request == currentConfiguration else {
                return .none
            }
            await refreshResourceStatus()
            guard generation == selectionGeneration, request == currentConfiguration else {
                return .none
            }
            if resourceState.translation == .needsDownload {
                translationPreparationGeneration &+= 1
                let translationRequest = TranslationPreparationRequest(
                    configuration: request,
                    token: translationPreparationGeneration
                )
                activeTranslationPreparation = translationRequest
                preparationPhase = .preparingTranslation
                return .prepareTranslation(translationRequest)
            }
            activeTranslationPreparation = nil
            preparationPhase = .idle
            return .none
        } catch {
            guard generation == selectionGeneration, request == currentConfiguration else {
                return .none
            }
            activeTranslationPreparation = nil
            preparationPhase = .idle
            modelErrorMessage = "模型准备失败：\(error.localizedDescription)"
            refreshErrorMessage()
            return .none
        }
    }

    func finishTranslationPreparation(
        for request: TranslationPreparationRequest,
        error: (any Error)?
    ) async {
        guard request == activeTranslationPreparation,
              request.configuration == currentConfiguration else {
            return
        }
        activeTranslationPreparation = nil
        preparationPhase = .idle
        modelErrorMessage = error.map { "翻译模型准备失败：\($0.localizedDescription)" }
        await refreshResourceStatus()
        refreshErrorMessage()
    }

    func refreshCaption() {
        guard let store else {
            return
        }
        do {
            guard let incomingSnapshot = try store.load() else {
                return
            }
            guard latestSnapshot.map({ incomingSnapshot.revision > $0.revision }) ?? true else {
                return
            }
            latestSnapshot = incomingSnapshot
        } catch {
            captionErrorMessage = "字幕状态读取失败：\(error.localizedDescription)"
            refreshErrorMessage()
        }
    }

    func startCaptionObservation() {
        captionObservationTask?.cancel()
        captionObservationTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(250))
                } catch is CancellationError {
                    return
                } catch {
                    return
                }

                guard !Task.isCancelled else {
                    return
                }
                self?.refreshCaption()
            }
        }
    }

    func stopCaptionObservation() {
        captionObservationTask?.cancel()
        captionObservationTask = nil
    }

    deinit {
        captionObservationTask?.cancel()
    }

    private static let unknownResourceState = LanguagePairResourceState(
        speech: .init(status: .unknown, isReserved: false),
        translation: .unknown
    )

    private func nextRequestGeneration() -> UInt64 {
        requestGeneration &+= 1
        return requestGeneration
    }

    private func selectionDidChange() {
        selectionGeneration &+= 1
        preparationPhase = .idle
        activeTranslationPreparation = nil
        resourceState = Self.unknownResourceState
        modelErrorMessage = nil
        refreshErrorMessage()
    }

    private func persistCurrentConfiguration() {
        guard let currentConfiguration else { return }
        languageStore.save(currentConfiguration)
    }

    private func resolveSelection(
        saved: LanguagePairConfiguration?,
        snapshot: LanguageCatalogSnapshot
    ) -> (input: SpeechLanguageOption, output: TranslationLanguageOption) {
        if let saved,
           let input = snapshot.inputLanguages.first(where: {
               $0.localeIdentifier == saved.sourceSpeechLocaleIdentifier
                   && $0.translationLanguageIdentifier == saved.sourceTranslationLanguageIdentifier
           }),
           let output = snapshot.outputLanguages.first(where: {
               $0.languageIdentifier == saved.targetTranslationLanguageIdentifier
           }) {
            return (input, output)
        }

        let input = preferredSystemInput(from: snapshot.inputLanguages)
            ?? snapshot.inputLanguages[0]
        let output = snapshot.outputLanguages.first(where: {
            $0.languageIdentifier == "zh-Hans"
        }) ?? snapshot.outputLanguages[0]
        return (input, output)
    }

    private func preferredSystemInput(
        from options: [SpeechLanguageOption]
    ) -> SpeechLanguageOption? {
        let current = Locale.current
        let canonicalIdentifier = Locale.canonicalIdentifier(from: current.identifier)
        if let exact = options.first(where: {
            Locale.canonicalIdentifier(from: $0.localeIdentifier) == canonicalIdentifier
        }) {
            return exact
        }

        guard let languageCode = current.language.languageCode?.identifier else {
            return nil
        }
        return options.first(where: {
            Locale(identifier: $0.localeIdentifier).language.languageCode?.identifier == languageCode
        })
    }

    private func refreshErrorMessage() {
        errorMessage = storageErrorMessage
            ?? captionErrorMessage
            ?? languageCatalogErrorMessage
            ?? modelErrorMessage
    }

    private var isBroadcastActive: Bool {
        switch latestSnapshot?.phase {
        case .broadcasting, .recognizing, .translating:
            true
        default:
            false
        }
    }
}

private struct UnavailableLanguageConfigurationStore: LanguageConfigurationStoring {
    func load() -> LanguagePairConfiguration? {
        nil
    }

    func save(_ configuration: LanguagePairConfiguration) {}
}

private enum LanguageCatalogLoadError: LocalizedError {
    case emptyCatalog

    var errorDescription: String? {
        "系统未返回可用的输入和输出语言。"
    }
}
