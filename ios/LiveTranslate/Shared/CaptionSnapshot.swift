import Foundation

struct CaptionSnapshot: Codable, Equatable, Sendable {
    let sessionIdentifier: UUID?
    let revision: UInt64
    let sourceText: String
    let translatedText: String
    let phase: SessionPhase
    let errorMessage: String?
    let updatedAt: Date

    init(
        sessionIdentifier: UUID? = nil,
        revision: UInt64,
        sourceText: String,
        translatedText: String,
        phase: SessionPhase,
        errorMessage: String?,
        updatedAt: Date
    ) {
        self.sessionIdentifier = sessionIdentifier
        self.revision = revision
        self.sourceText = sourceText
        self.translatedText = translatedText
        self.phase = phase
        self.errorMessage = errorMessage
        self.updatedAt = updatedAt
    }
}
