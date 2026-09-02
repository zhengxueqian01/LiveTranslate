import Foundation
@preconcurrency import Translation

enum AppleTranslationClientError: LocalizedError, Sendable {
    case languageResourcesNotInstalled(source: String, target: String)
    case unsupportedLanguagePair(source: String, target: String)
    case translationFailed(source: String, target: String, message: String)

    var errorDescription: String? {
        switch self {
        case .languageResourcesNotInstalled(let source, let target):
            "本机尚未安装 \(source) 到 \(target) 的翻译资源，请返回主 App 完成模型准备。"
        case .unsupportedLanguagePair(let source, let target):
            "系统不支持 \(source) 到 \(target) 的端侧翻译。"
        case .translationFailed(let source, let target, let message):
            "\(source) 到 \(target) 的端侧翻译失败：\(message)"
        }
    }
}

struct AppleTranslationClientBuilder: BroadcastTranslationClientBuilding {
    func makeTranslationClient(
        configuration: TranslationClientConfiguration
    ) -> any CaptionTranslating {
        AppleTranslationClient(configuration: configuration)
    }
}

actor AppleTranslationClient: CaptionTranslating {
    private let configuration: TranslationClientConfiguration
    private let source: Locale.Language
    private let target: Locale.Language
    private let session: TranslationSession
    private let serialExecutor = AsyncSerialExecutor()
    private var didVerifyResources = false

    init(configuration: TranslationClientConfiguration) {
        self.configuration = configuration
        source = Locale.Language(identifier: configuration.sourceIdentifier)
        target = Locale.Language(identifier: configuration.targetIdentifier)
        if #available(iOS 26.4, *) {
            session = TranslationSession(
                installedSource: source,
                target: target,
                preferredStrategy: .lowLatency
            )
        } else {
            session = TranslationSession(
                installedSource: source,
                target: target
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
            throw AppleTranslationClientError.languageResourcesNotInstalled(
                source: configuration.sourceIdentifier,
                target: configuration.targetIdentifier
            )
        } catch {
            throw AppleTranslationClientError.translationFailed(
                source: configuration.sourceIdentifier,
                target: configuration.targetIdentifier,
                message: error.localizedDescription
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
            throw AppleTranslationClientError.languageResourcesNotInstalled(
                source: configuration.sourceIdentifier,
                target: configuration.targetIdentifier
            )
        case .unsupported:
            throw AppleTranslationClientError.unsupportedLanguagePair(
                source: configuration.sourceIdentifier,
                target: configuration.targetIdentifier
            )
        @unknown default:
            throw AppleTranslationClientError.translationFailed(
                source: configuration.sourceIdentifier,
                target: configuration.targetIdentifier,
                message: "系统返回未知的语言资源状态。"
            )
        }
    }
}
