import Foundation
@preconcurrency import Speech
@preconcurrency import Translation

enum ModelResourceStatus: Equatable, Sendable {
    case unknown
    case unsupported
    case needsDownload
    case downloading
    case installed
    case notRequired
}

struct SpeechResourceState: Equatable, Sendable {
    let status: ModelResourceStatus
    let isReserved: Bool

    var isReady: Bool {
        status == .installed && isReserved
    }
}

struct LanguagePairResourceState: Equatable, Sendable {
    let speech: SpeechResourceState
    let translation: ModelResourceStatus

    var isReady: Bool {
        speech.isReady && (translation == .installed || translation == .notRequired)
    }
}

protocol LanguageResourceManaging: Sendable {
    func status(for configuration: LanguagePairConfiguration) async -> LanguagePairResourceState
    func prepareSpeech(localeIdentifier: String) async throws
    func reservedSpeechLocaleIdentifiers() async -> [String]
    func releaseSpeech(localeIdentifier: String) async -> Bool
}

enum LanguageResourceError: LocalizedError {
    case installationUnavailable
    case reservationUnavailable

    var errorDescription: String? {
        switch self {
        case .installationUnavailable:
            "系统未提供可下载的语音模型。"
        case .reservationUnavailable:
            "系统无法预留该语音模型。"
        }
    }
}

struct SystemLanguageResourceService: LanguageResourceManaging {
    func status(for configuration: LanguagePairConfiguration) async -> LanguagePairResourceState {
        let locale = Locale(identifier: configuration.sourceSpeechLocaleIdentifier)
        let module = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        let speech = map(await AssetInventory.status(forModules: [module]))
        let reserved = await AssetInventory.reservedLocales.contains { $0.identifier == locale.identifier }
        let translation: ModelResourceStatus
        if configuration.usesPassThroughTranslation {
            translation = .notRequired
        } else {
            let availability: LanguageAvailability
            if #available(iOS 26.4, *) {
                availability = LanguageAvailability(preferredStrategy: .lowLatency)
            } else {
                availability = LanguageAvailability()
            }
            translation = switch await availability.status(
                from: Locale.Language(identifier: configuration.sourceTranslationLanguageIdentifier),
                to: Locale.Language(identifier: configuration.targetTranslationLanguageIdentifier)
            ) {
            case .installed: .installed
            case .supported: .needsDownload
            case .unsupported: .unsupported
            @unknown default: .unknown
            }
        }
        return .init(speech: .init(status: speech, isReserved: reserved), translation: translation)
    }

    func prepareSpeech(localeIdentifier: String) async throws {
        let locale = Locale(identifier: localeIdentifier)
        let module = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        if await AssetInventory.status(forModules: [module]) != .installed {
            guard let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) else {
                throw LanguageResourceError.installationUnavailable
            }
            try await request.downloadAndInstall()
        }
        if await AssetInventory.reservedLocales.contains(where: { $0.identifier == locale.identifier }) {
            return
        }
        guard try await AssetInventory.reserve(locale: locale) else {
            throw LanguageResourceError.reservationUnavailable
        }
    }

    func reservedSpeechLocaleIdentifiers() async -> [String] {
        await AssetInventory.reservedLocales.map(\.identifier).sorted()
    }

    func releaseSpeech(localeIdentifier: String) async -> Bool {
        await AssetInventory.release(reservedLocale: Locale(identifier: localeIdentifier))
    }

    private func map(_ status: AssetInventory.Status) -> ModelResourceStatus {
        switch status {
        case .unsupported:
            .unsupported
        case .supported:
            .needsDownload
        case .downloading:
            .downloading
        case .installed:
            .installed
        @unknown default:
            .unknown
        }
    }
}
