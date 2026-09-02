import Combine
import Foundation
import SwiftUI

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
    private var configurationErrorMessage: String?
    private var modelErrorMessage: String?
    private var releaseErrorMessage: String?
    private var captionErrorMessage: String?
    private var captionObservationTask: Task<Void, Never>?
    private var requestGeneration: UInt64 = 0
    private var selectionGeneration: UInt64 = 0
    private var translationPreparationGeneration: UInt64 = 0
    private var activeTranslationPreparation: TranslationPreparationRequest?
    private var isReleasingSpeechModel = false

    var currentConfiguration: LanguagePairConfiguration? {
        guard let selectedInput, let selectedOutput else { return nil }
        return .init(
            sourceSpeechLocaleIdentifier: selectedInput.localeIdentifier,
            sourceTranslationLanguageIdentifier: selectedInput.translationLanguageIdentifier,
            targetTranslationLanguageIdentifier: selectedOutput.languageIdentifier
        )
    }

    var canStartBroadcast: Bool {
        store != nil
            && currentConfiguration != nil
            && resourceState.isReady
            && blockingErrorMessage == nil
    }

    var canReleaseSpeechModels: Bool {
        store != nil
            && preparationPhase == .idle
            && !isReleasingSpeechModel
            && !isBroadcastActive
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
        configurationErrorMessage = nil
        modelErrorMessage = nil
        releaseErrorMessage = nil
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
        configurationErrorMessage = nil
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
            switch languageStore.loadResult() {
            case .missing:
                let resolved = defaultSelection(in: snapshot)
                selectedInput = resolved.input
                selectedOutput = resolved.output
                persistCurrentConfiguration()
            case .configuration(let saved):
                guard let resolved = resolveSavedSelection(
                    saved: saved,
                    snapshot: snapshot
                ) else {
                    invalidateSavedSelection()
                    return
                }
                selectedInput = resolved.input
                selectedOutput = resolved.output
            case .invalid:
                invalidateSavedSelection()
                return
            }
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

    func loadLanguagesIfNeeded() async {
        guard inputLanguages.isEmpty || outputLanguages.isEmpty else {
            return
        }
        await loadLanguages()
    }

    func selectInput(identifier: String) async {
        guard setInputSelection(identifier: identifier) else {
            return
        }
        await refreshResourceStatus()
    }

    func selectOutput(identifier: String) async {
        guard setOutputSelection(identifier: identifier) else {
            return
        }
        await refreshResourceStatus()
    }

    @discardableResult
    func setInputSelection(identifier: String) -> Bool {
        guard let option = inputLanguages.first(where: { $0.localeIdentifier == identifier }) else {
            return false
        }
        selectedInput = option
        selectionDidChange()
        persistCurrentConfiguration()
        return true
    }

    @discardableResult
    func setOutputSelection(identifier: String) -> Bool {
        guard let option = outputLanguages.first(where: { $0.languageIdentifier == identifier }) else {
            return false
        }
        selectedOutput = option
        selectionDidChange()
        persistCurrentConfiguration()
        return true
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
        if state.isReady {
            modelErrorMessage = nil
        }
        refreshErrorMessage()
    }

    func loadReservedSpeechLocales() async {
        reservedSpeechLocaleIdentifiers = await resourceService.reservedSpeechLocaleIdentifiers()
    }

    func releaseSpeechLocale(_ identifier: String) async {
        guard preparationPhase == .idle,
              !isReleasingSpeechModel,
              !isBroadcastActive,
              let store else {
            return
        }
        isReleasingSpeechModel = true
        defer { isReleasingSpeechModel = false }

        let sharedSnapshot: CaptionSnapshot?
        do {
            sharedSnapshot = try store.load()
        } catch {
            return
        }
        guard !Self.isBroadcastActive(sharedSnapshot?.phase) else {
            return
        }
        guard await resourceService.releaseSpeech(localeIdentifier: identifier) else {
            releaseErrorMessage = "无法释放语音模型 \(identifier)。"
            refreshErrorMessage()
            return
        }
        releaseErrorMessage = nil
        refreshErrorMessage()
        await loadReservedSpeechLocales()
        if currentConfiguration?.sourceSpeechLocaleIdentifier == identifier {
            await refreshResourceStatus()
        }
    }

    func beginModelPreparation() async -> ModelPreparationAction {
        guard !isReleasingSpeechModel,
              preparationPhase == .idle,
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
            await refreshResourceStatus()
            guard generation == selectionGeneration, request == currentConfiguration else {
                return .none
            }
            modelErrorMessage = resourceState.isReady
                ? nil
                : "模型准备失败：\(error.localizedDescription)"
            refreshErrorMessage()
            return .none
        }
    }

    func finishTranslationPreparation(
        for request: TranslationPreparationRequest,
        error: (any Error)?
    ) async {
        let generation = selectionGeneration
        let configuration = request.configuration
        guard request == activeTranslationPreparation,
              configuration == currentConfiguration else {
            return
        }
        activeTranslationPreparation = nil
        preparationPhase = .idle
        await refreshResourceStatus()
        guard generation == selectionGeneration,
              configuration == currentConfiguration else {
            return
        }
        modelErrorMessage = resourceState.isReady
            ? nil
            : error.map { "翻译模型准备失败：\($0.localizedDescription)" }
        refreshErrorMessage()
    }

    func refreshCaption() {
        guard let store else {
            return
        }
        do {
            let incomingSnapshot = try store.load()
            captionErrorMessage = nil
            refreshErrorMessage()
            guard let incomingSnapshot else {
                return
            }
            guard Self.shouldAccept(
                incomingSnapshot,
                replacing: latestSnapshot
            ) else {
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
        if currentConfiguration != nil {
            configurationErrorMessage = nil
        }
        refreshErrorMessage()
    }

    private func persistCurrentConfiguration() {
        guard let currentConfiguration else { return }
        languageStore.save(currentConfiguration)
    }

    private func resolveSavedSelection(
        saved: LanguagePairConfiguration,
        snapshot: LanguageCatalogSnapshot
    ) -> (input: SpeechLanguageOption, output: TranslationLanguageOption)? {
        guard let input = snapshot.inputLanguages.first(where: {
            $0.localeIdentifier == saved.sourceSpeechLocaleIdentifier
                && $0.translationLanguageIdentifier == saved.sourceTranslationLanguageIdentifier
        }),
        let output = snapshot.outputLanguages.first(where: {
            $0.languageIdentifier == saved.targetTranslationLanguageIdentifier
        }) else {
            return nil
        }
        return (input, output)
    }

    private func defaultSelection(
        in snapshot: LanguageCatalogSnapshot
    ) -> (input: SpeechLanguageOption, output: TranslationLanguageOption) {
        let input = preferredSystemInput(from: snapshot.inputLanguages)
            ?? snapshot.inputLanguages[0]
        let output = snapshot.outputLanguages.first(where: {
            $0.languageIdentifier == "zh-Hans"
        }) ?? preferredSystemOutput(from: snapshot.outputLanguages)
            ?? snapshot.outputLanguages[0]
        return (input, output)
    }

    private func preferredSystemInput(
        from options: [SpeechLanguageOption]
    ) -> SpeechLanguageOption? {
        let current = displayLocale
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

    private func preferredSystemOutput(
        from options: [TranslationLanguageOption]
    ) -> TranslationLanguageOption? {
        let language = displayLocale.language
        let candidates = [
            language.minimalIdentifier,
            language.languageCode?.identifier
        ].compactMap { $0 }
        return candidates.lazy.compactMap { candidate in
            options.first(where: { $0.languageIdentifier == candidate })
        }.first
    }

    private func invalidateSavedSelection() {
        selectedInput = nil
        selectedOutput = nil
        resourceState = Self.unknownResourceState
        preparationPhase = .idle
        activeTranslationPreparation = nil
        configurationErrorMessage =
            "已保存的语言配置不可用，请重新选择输入语言和目标语言。"
        refreshErrorMessage()
    }

    private func refreshErrorMessage() {
        errorMessage = blockingErrorMessage
            ?? releaseErrorMessage
            ?? captionErrorMessage
    }

    private var blockingErrorMessage: String? {
        storageErrorMessage
            ?? configurationErrorMessage
            ?? languageCatalogErrorMessage
            ?? modelErrorMessage
    }

    private var isBroadcastActive: Bool {
        Self.isBroadcastActive(latestSnapshot?.phase)
    }

    private static func isBroadcastActive(_ phase: SessionPhase?) -> Bool {
        switch phase {
        case .broadcasting, .recognizing, .translating:
            true
        default:
            false
        }
    }

    private static func shouldAccept(
        _ incoming: CaptionSnapshot,
        replacing current: CaptionSnapshot?
    ) -> Bool {
        guard let current else { return true }
        if let incomingSession = incoming.sessionIdentifier {
            return incomingSession != current.sessionIdentifier
                || incoming.revision > current.revision
        }
        return current.sessionIdentifier == nil
            && incoming.revision > current.revision
    }
}

private struct UnavailableLanguageConfigurationStore: LanguageConfigurationStoring {
    func loadResult() -> LanguageConfigurationLoadResult {
        .missing
    }

    func save(_ configuration: LanguagePairConfiguration) {}
}

private enum LanguageCatalogLoadError: LocalizedError {
    case emptyCatalog

    var errorDescription: String? {
        "系统未返回可用的输入和输出语言。"
    }
}
