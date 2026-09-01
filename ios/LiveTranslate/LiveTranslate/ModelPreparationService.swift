import Speech

enum ModelPreparationError: LocalizedError {
    case installationUnavailable

    var errorDescription: String? {
        switch self {
        case .installationUnavailable:
            "系统未提供可下载的语音模型。"
        }
    }
}

struct ModelPreparationService: ModelPreparing {
    func speechStatus(for source: SourceLanguage) async -> ModelResourceStatus {
        let modules = makeModules(for: source)
        switch await AssetInventory.status(forModules: modules) {
        case .unsupported:
            return .unsupported
        case .supported:
            return .needsDownload
        case .downloading:
            return .downloading
        case .installed:
            return .installed
        @unknown default:
            return .unknown
        }
    }

    func installSpeechModel(for source: SourceLanguage) async throws {
        let modules = makeModules(for: source)
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: modules) else {
            if await AssetInventory.status(forModules: modules) == .installed {
                return
            }
            throw ModelPreparationError.installationUnavailable
        }
        try await request.downloadAndInstall()
    }

    private func makeModules(for source: SourceLanguage) -> [any SpeechModule] {
        [SpeechTranscriber(locale: source.speechLocale, preset: .progressiveTranscription)]
    }
}
