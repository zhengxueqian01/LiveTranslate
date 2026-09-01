import Foundation
@testable import LiveTranslate

final class InMemoryCaptionStore: CaptionStoreProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: CaptionSnapshot?

    func load() throws -> CaptionSnapshot? {
        lock.withLock { snapshot }
    }

    func save(_ snapshot: CaptionSnapshot) throws {
        lock.withLock { self.snapshot = snapshot }
    }

    func clear() throws {
        lock.withLock { snapshot = nil }
    }
}

struct FakeModelPreparationService: ModelPreparing {
    let status: ModelResourceStatus

    func speechStatus(for source: SourceLanguage) async -> ModelResourceStatus {
        status
    }

    func installSpeechModel(for source: SourceLanguage) async throws {}
}

actor ControlledModelPreparationService: ModelPreparing {
    private var statusContinuations: [(SourceLanguage, CheckedContinuation<ModelResourceStatus, Never>)] = []
    private var requestContinuations: [(SourceLanguage, CheckedContinuation<Void, Never>)] = []
    private var installationContinuations: [(SourceLanguage, CheckedContinuation<Void, Error>)] = []
    private var installationRequestContinuations: [(SourceLanguage, CheckedContinuation<Void, Never>)] = []

    func speechStatus(for source: SourceLanguage) async -> ModelResourceStatus {
        if let index = requestContinuations.firstIndex(where: { $0.0 == source }) {
            requestContinuations.remove(at: index).1.resume()
        }
        return await withCheckedContinuation { continuation in
            statusContinuations.append((source, continuation))
        }
    }

    func installSpeechModel(for source: SourceLanguage) async throws {
        if let index = installationRequestContinuations.firstIndex(where: { $0.0 == source }) {
            installationRequestContinuations.remove(at: index).1.resume()
        }
        try await withCheckedThrowingContinuation { continuation in
            installationContinuations.append((source, continuation))
        }
    }

    func waitForStatusRequest(for source: SourceLanguage) async {
        if statusContinuations.contains(where: { $0.0 == source }) {
            return
        }
        await withCheckedContinuation { continuation in
            requestContinuations.append((source, continuation))
        }
    }

    func resolveStatus(for source: SourceLanguage, with status: ModelResourceStatus) {
        guard let index = statusContinuations.firstIndex(where: { $0.0 == source }) else {
            return
        }
        statusContinuations.remove(at: index).1.resume(returning: status)
    }

    func waitForInstallationRequest(for source: SourceLanguage) async {
        if installationContinuations.contains(where: { $0.0 == source }) {
            return
        }
        await withCheckedContinuation { continuation in
            installationRequestContinuations.append((source, continuation))
        }
    }

    func failInstallation(for source: SourceLanguage) {
        guard let index = installationContinuations.firstIndex(where: { $0.0 == source }) else {
            return
        }
        installationContinuations.remove(at: index).1.resume(
            throwing: ModelPreparationTestError.installationFailed
        )
    }
}

enum ModelPreparationTestError: LocalizedError, Sendable {
    case installationFailed

    var errorDescription: String? {
        "模拟安装失败"
    }
}
