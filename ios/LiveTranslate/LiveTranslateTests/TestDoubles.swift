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
