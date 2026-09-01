enum SessionPhase: String, Codable, Sendable {
    case idle
    case preparingModels
    case ready
    case broadcasting
    case recognizing
    case translating
    case stopped
    case failed
}
