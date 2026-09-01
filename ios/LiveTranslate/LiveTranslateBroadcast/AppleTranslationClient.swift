import Foundation
@preconcurrency import Translation

enum AppleTranslationClientError: LocalizedError, Sendable {
    case languageResourcesNotInstalled
    case unsupportedLanguagePair
    case translationFailed(String)

    var errorDescription: String? {
        switch self {
        case .languageResourcesNotInstalled:
            "本机尚未安装当前来源语言到简体中文的翻译资源，请返回主 App 完成模型准备。"
        case .unsupportedLanguagePair:
            "系统不支持当前来源语言到简体中文的端侧翻译。"
        case .translationFailed(let message):
            "端侧翻译失败：\(message)"
        }
    }
}

actor AppleTranslationClient: CaptionTranslating {
    private let source: Locale.Language
    private let target = SourceLanguage.translationTarget
    private let session: TranslationSession
    private let serialExecutor = AsyncSerialExecutor()
    private var didVerifyResources = false

    init(source: SourceLanguage) {
        self.source = source.translationSource
        if #available(iOS 26.4, *) {
            session = TranslationSession(
                installedSource: source.translationSource,
                target: SourceLanguage.translationTarget,
                preferredStrategy: .lowLatency
            )
        } else {
            session = TranslationSession(
                installedSource: source.translationSource,
                target: SourceLanguage.translationTarget
            )
        }
    }

    func translate(_ text: String) async throws -> String {
        try await serialExecutor.run { [self] in
            try await translateSerially(text)
        }
    }

    private func translateSerially(_ text: String) async throws -> String {
        if !didVerifyResources {
            try await verifyResources()
            didVerifyResources = true
        }

        do {
            return try await session.translate(text).targetText
        } catch let error where TranslationError.notInstalled ~= error {
            throw AppleTranslationClientError.languageResourcesNotInstalled
        } catch {
            throw AppleTranslationClientError.translationFailed(
                error.localizedDescription
            )
        }
    }

    private func verifyResources() async throws {
        let availability: LanguageAvailability
        if #available(iOS 26.4, *) {
            availability = LanguageAvailability(preferredStrategy: .lowLatency)
        } else {
            availability = LanguageAvailability()
        }

        switch await availability.status(from: source, to: target) {
        case .installed:
            return
        case .supported:
            throw AppleTranslationClientError.languageResourcesNotInstalled
        case .unsupported:
            throw AppleTranslationClientError.unsupportedLanguagePair
        @unknown default:
            throw AppleTranslationClientError.translationFailed(
                "系统返回未知的语言资源状态。"
            )
        }
    }
}
