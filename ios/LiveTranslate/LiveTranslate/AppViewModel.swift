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
    @Published var selectedLanguage: SourceLanguage = .english
    @Published private(set) var speechStatus: ModelResourceStatus = .unknown
    @Published private(set) var isTranslationReady = false
    @Published private(set) var latestSnapshot: CaptionSnapshot?
    @Published private(set) var errorMessage: String?

    private let modelService: any ModelPreparing
    private let store: (any CaptionStoreProtocol)?

    var canStartBroadcast: Bool {
        speechStatus == .installed && isTranslationReady && errorMessage == nil
    }

    init(modelService: any ModelPreparing, store: any CaptionStoreProtocol) {
        self.modelService = modelService
        self.store = store
    }

    private init(modelService: any ModelPreparing, errorMessage: String) {
        self.modelService = modelService
        store = nil
        self.errorMessage = errorMessage
    }

    static func live() -> AppViewModel {
        do {
            return AppViewModel(
                modelService: ModelPreparationService(),
                store: try CaptionStore()
            )
        } catch {
            return AppViewModel(
                modelService: ModelPreparationService(),
                errorMessage: "无法打开 App Group，请检查两个 Target 的签名与 App Group 配置。"
            )
        }
    }

    func refreshModelStatus() async {
        speechStatus = await modelService.speechStatus(for: selectedLanguage)
    }

    func installSpeechModel() async {
        speechStatus = .downloading
        errorMessage = nil
        do {
            try await modelService.installSpeechModel(for: selectedLanguage)
            await refreshModelStatus()
        } catch {
            speechStatus = .needsDownload
            errorMessage = "语音模型下载失败：\(error.localizedDescription)"
        }
    }

    func markTranslationReady() {
        isTranslationReady = true
        errorMessage = nil
    }

    func markTranslationNeedsPreparation() {
        isTranslationReady = false
    }

    func reportTranslationError(_ error: any Error) {
        isTranslationReady = false
        errorMessage = "翻译模型准备失败：\(error.localizedDescription)"
    }

    func refreshCaption() {
        guard let store else {
            return
        }
        do {
            latestSnapshot = try store.load()
        } catch {
            errorMessage = "字幕状态读取失败：\(error.localizedDescription)"
        }
    }
}
