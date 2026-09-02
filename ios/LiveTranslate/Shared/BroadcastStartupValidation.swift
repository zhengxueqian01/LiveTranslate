import Foundation

enum BroadcastInstalledResourceStatus: Equatable, Sendable {
    case installed
    case available
    case unsupported
    case unknown
}

enum BroadcastStartupValidationError: LocalizedError, Equatable, Sendable {
    case speechResourcesNotInstalled(localeIdentifier: String)
    case speechLocaleUnsupported(localeIdentifier: String)
    case speechStatusUnknown(localeIdentifier: String)
    case translationResourcesNotInstalled(source: String, target: String)
    case translationPairUnsupported(source: String, target: String)
    case translationStatusUnknown(source: String, target: String)

    var errorDescription: String? {
        switch self {
        case .speechResourcesNotInstalled(let localeIdentifier):
            "本机尚未安装或预留 \(localeIdentifier) 的语音识别资源，请返回主 App 完成模型准备。"
        case .speechLocaleUnsupported(let localeIdentifier):
            "系统不支持 \(localeIdentifier) 的端侧语音识别。"
        case .speechStatusUnknown(let localeIdentifier):
            "系统无法确认 \(localeIdentifier) 的语音识别资源状态。"
        case .translationResourcesNotInstalled(let source, let target):
            "本机尚未安装 \(source) 到 \(target) 的翻译资源，请返回主 App 完成模型准备。"
        case .translationPairUnsupported(let source, let target):
            "系统不支持 \(source) 到 \(target) 的端侧翻译。"
        case .translationStatusUnknown(let source, let target):
            "系统无法确认 \(source) 到 \(target) 的翻译资源状态。"
        }
    }
}

protocol BroadcastInstalledResourceChecking: Sendable {
    func speechStatus(localeIdentifier: String) async -> BroadcastInstalledResourceStatus
    func translationStatus(
        sourceIdentifier: String,
        targetIdentifier: String
    ) async -> BroadcastInstalledResourceStatus
}

protocol BroadcastTranslationClientBuilding: Sendable {
    func makeTranslationClient(
        configuration: TranslationClientConfiguration
    ) -> any CaptionTranslating
}

struct BroadcastStartupResources: Sendable {
    let sourceSpeechLocaleIdentifier: String
    let translator: any CaptionTranslating
}

struct BroadcastStartupPreparer: Sendable {
    private let checker: any BroadcastInstalledResourceChecking
    private let translationClientBuilder: any BroadcastTranslationClientBuilding

    init(
        checker: any BroadcastInstalledResourceChecking,
        translationClientBuilder: any BroadcastTranslationClientBuilding
    ) {
        self.checker = checker
        self.translationClientBuilder = translationClientBuilder
    }

    func prepare(
        configuration: LanguagePairConfiguration
    ) async throws -> BroadcastStartupResources {
        try await validateSpeech(
            localeIdentifier: configuration.sourceSpeechLocaleIdentifier
        )
        try Task.checkCancellation()

        let translator: any CaptionTranslating
        if configuration.usesPassThroughTranslation {
            translator = PassThroughTranslationClient()
        } else {
            try await validateTranslation(
                sourceIdentifier: configuration.sourceTranslationLanguageIdentifier,
                targetIdentifier: configuration.targetTranslationLanguageIdentifier
            )
            try Task.checkCancellation()
            translator = translationClientBuilder.makeTranslationClient(
                configuration: TranslationClientConfiguration(configuration)
            )
        }
        return BroadcastStartupResources(
            sourceSpeechLocaleIdentifier: configuration.sourceSpeechLocaleIdentifier,
            translator: translator
        )
    }

    private func validateSpeech(localeIdentifier: String) async throws {
        switch await checker.speechStatus(localeIdentifier: localeIdentifier) {
        case .installed:
            return
        case .available:
            throw BroadcastStartupValidationError.speechResourcesNotInstalled(
                localeIdentifier: localeIdentifier
            )
        case .unsupported:
            throw BroadcastStartupValidationError.speechLocaleUnsupported(
                localeIdentifier: localeIdentifier
            )
        case .unknown:
            throw BroadcastStartupValidationError.speechStatusUnknown(
                localeIdentifier: localeIdentifier
            )
        }
    }

    private func validateTranslation(
        sourceIdentifier: String,
        targetIdentifier: String
    ) async throws {
        switch await checker.translationStatus(
            sourceIdentifier: sourceIdentifier,
            targetIdentifier: targetIdentifier
        ) {
        case .installed:
            return
        case .available:
            throw BroadcastStartupValidationError.translationResourcesNotInstalled(
                source: sourceIdentifier,
                target: targetIdentifier
            )
        case .unsupported:
            throw BroadcastStartupValidationError.translationPairUnsupported(
                source: sourceIdentifier,
                target: targetIdentifier
            )
        case .unknown:
            throw BroadcastStartupValidationError.translationStatusUnknown(
                source: sourceIdentifier,
                target: targetIdentifier
            )
        }
    }
}
