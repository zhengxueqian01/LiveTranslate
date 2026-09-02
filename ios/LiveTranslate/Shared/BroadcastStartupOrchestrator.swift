import Foundation

struct BroadcastStartupSession: Sendable {
    let sourceSpeechLocaleIdentifier: String
    let coordinator: BroadcastCaptionCoordinator
}

struct BroadcastStartupOrchestrator: Sendable {
    private let preparer: BroadcastStartupPreparer
    private let makeCoordinator: @Sendable (
        String,
        any CaptionTranslating
    ) -> BroadcastCaptionCoordinator

    init(
        preparer: BroadcastStartupPreparer,
        makeCoordinator: @escaping @Sendable (
            String,
            any CaptionTranslating
        ) -> BroadcastCaptionCoordinator
    ) {
        self.preparer = preparer
        self.makeCoordinator = makeCoordinator
    }

    func start(
        configuration: LanguagePairConfiguration,
        beforeBeginning: @escaping @Sendable () throws -> Void = {},
        acceptAudio: @escaping @Sendable (BroadcastStartupSession) throws -> Void
    ) async throws -> BroadcastStartupSession {
        let resources = try await preparer.prepare(configuration: configuration)
        try Task.checkCancellation()

        let coordinator = makeCoordinator(
            resources.sourceSpeechLocaleIdentifier,
            resources.translator
        )
        try beforeBeginning()
        try coordinator.begin()
        let session = BroadcastStartupSession(
            sourceSpeechLocaleIdentifier: resources.sourceSpeechLocaleIdentifier,
            coordinator: coordinator
        )
        do {
            try acceptAudio(session)
            return session
        } catch {
            try? coordinator.stop()
            throw error
        }
    }
}
