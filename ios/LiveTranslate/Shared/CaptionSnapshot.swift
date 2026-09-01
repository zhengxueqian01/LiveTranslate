import Foundation

struct CaptionSnapshot: Codable, Equatable, Sendable {
    let revision: UInt64
    let sourceText: String
    let translatedText: String
    let phase: SessionPhase
    let errorMessage: String?
    let updatedAt: Date
}
