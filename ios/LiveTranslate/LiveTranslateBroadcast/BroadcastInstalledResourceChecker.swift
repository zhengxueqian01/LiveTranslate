import Foundation
@preconcurrency import Speech
@preconcurrency import Translation

struct SystemBroadcastInstalledResourceChecker: BroadcastInstalledResourceChecking {
    private let speechResolver = BroadcastSpeechResourceResolver(
        inventory: SystemBroadcastSpeechAssetInventory()
    )

    func speechStatus(
        localeIdentifier: String
    ) async -> BroadcastInstalledResourceStatus {
        await speechResolver.status(localeIdentifier: localeIdentifier)
    }

    func translationStatus(
        sourceIdentifier: String,
        targetIdentifier: String
    ) async -> BroadcastInstalledResourceStatus {
        let source = Locale.Language(identifier: sourceIdentifier)
        let target = Locale.Language(identifier: targetIdentifier)
        let availability: LanguageAvailability
        if #available(iOS 26.4, *) {
            availability = LanguageAvailability(preferredStrategy: .lowLatency)
        } else {
            availability = LanguageAvailability()
        }

        switch await availability.status(from: source, to: target) {
        case .installed:
            return .installed
        case .supported:
            return .available
        case .unsupported:
            return .unsupported
        @unknown default:
            return .unknown
        }
    }
}

private struct SystemBroadcastSpeechAssetInventory: BroadcastSpeechAssetInventoryAccessing {
    func installationStatus(
        localeIdentifier: String
    ) async -> BroadcastInstalledResourceStatus {
        let locale = Locale(identifier: localeIdentifier)
        let module = SpeechTranscriber(
            locale: locale,
            preset: .progressiveTranscription
        )

        switch await AssetInventory.status(forModules: [module]) {
        case .installed:
            return .installed
        case .supported, .downloading:
            return .available
        case .unsupported:
            return .unsupported
        @unknown default:
            return .unknown
        }
    }

    func reservedLocaleIdentifiers() async -> [String] {
        await AssetInventory.reservedLocales.map(\.identifier)
    }

    func reserve(localeIdentifier: String) async throws -> Bool {
        try await AssetInventory.reserve(locale: Locale(identifier: localeIdentifier))
    }
}
