import Combine
import Foundation
import SwiftUI

enum ModelResourceStatus: Equatable, Sendable {
    case unknown
    case unsupported
    case needsDownload
    case downloading
    case installed
}

protocol ModelPreparing: Sendable {
    func speechStatus(for source: SourceLanguage) async -> ModelResourceStatus
    func installSpeechModel(for source: SourceLanguage) async throws
}

@MainActor
final class AppViewModel: ObservableObject {
    @Published var selectedLanguage: SourceLanguage {
        didSet {
            languageStore?.save(selectedLanguage)
        }
    }
    @Published private(set) var speechStatus: ModelResourceStatus = .unknown
    @Published private(set) var isTranslationReady = false
    @Published private(set) var latestSnapshot: CaptionSnapshot?
    @Published private(set) var errorMessage: String?

    private let modelService: any ModelPreparing
    private let store: (any CaptionStoreProtocol)?
    private let languageStore: SourceLanguageStore?
    private let storageErrorMessage: String?
    private var speechErrorMessage: String?
    private var translationErrorMessage: String?
    private var captionErrorMessage: String?
    private var captionObservationTask: Task<Void, Never>?

    var canStartBroadcast: Bool {
        store != nil && speechStatus == .installed && isTranslationReady && errorMessage == nil
    }

    init(
        modelService: any ModelPreparing,
        store: (any CaptionStoreProtocol)?,
        languageStore: SourceLanguageStore
    ) {
        self.modelService = modelService
        self.store = store
        self.languageStore = languageStore
        storageErrorMessage = store == nil
            ? "无法打开 App Group，请检查两个 Target 的签名与 App Group 配置。"
            : nil
        speechErrorMessage = nil
        translationErrorMessage = nil
        captionErrorMessage = nil
        captionObservationTask = nil
        selectedLanguage = languageStore.load() ?? .english
        errorMessage = storageErrorMessage
    }

    private init(modelService: any ModelPreparing, errorMessage: String) {
        self.modelService = modelService
        store = nil
        languageStore = nil
        storageErrorMessage = errorMessage
        speechErrorMessage = nil
        translationErrorMessage = nil
        captionErrorMessage = nil
        captionObservationTask = nil
        selectedLanguage = .english
        self.errorMessage = errorMessage
    }

    static func live() -> AppViewModel {
        guard let defaults = UserDefaults(suiteName: CaptionStore.appGroupIdentifier) else {
            return AppViewModel(
                modelService: ModelPreparationService(),
                errorMessage: "无法打开 App Group，请检查两个 Target 的签名与 App Group 配置。"
            )
        }
        return AppViewModel(
            modelService: ModelPreparationService(),
            store: CaptionStore(defaults: defaults),
            languageStore: SourceLanguageStore(defaults: defaults)
        )
    }

    func refreshModelStatus() async {
        let source = selectedLanguage
        let status = await modelService.speechStatus(for: source)
        guard source == selectedLanguage else {
            return
        }
        speechStatus = status
    }

    func installSpeechModel() async {
        let source = selectedLanguage
        speechStatus = .downloading
        speechErrorMessage = nil
        refreshErrorMessage()
        do {
            try await modelService.installSpeechModel(for: source)
            guard source == selectedLanguage else {
                return
            }
            await refreshModelStatus()
        } catch {
            guard source == selectedLanguage else {
                return
            }
            speechStatus = .needsDownload
            speechErrorMessage = "语音模型下载失败：\(error.localizedDescription)"
            refreshErrorMessage()
        }
    }

    func markTranslationReady(for source: SourceLanguage) {
        guard source == selectedLanguage else {
            return
        }
        isTranslationReady = true
        translationErrorMessage = nil
        refreshErrorMessage()
    }

    func markTranslationReady() {
        markTranslationReady(for: selectedLanguage)
    }

    func markTranslationNeedsPreparation() {
        isTranslationReady = false
    }

    func reportTranslationError(_ error: any Error, for source: SourceLanguage) {
        guard source == selectedLanguage else {
            return
        }
        isTranslationReady = false
        translationErrorMessage = "翻译模型准备失败：\(error.localizedDescription)"
        refreshErrorMessage()
    }

    func reportTranslationError(_ error: any Error) {
        reportTranslationError(error, for: selectedLanguage)
    }

    func refreshCaption() {
        guard let store else {
            return
        }
        do {
            latestSnapshot = try store.load()
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

    private func refreshErrorMessage() {
        errorMessage = storageErrorMessage
            ?? captionErrorMessage
            ?? speechErrorMessage
            ?? translationErrorMessage
    }
}
