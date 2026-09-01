import Foundation

enum SourceLanguage: String, CaseIterable, Codable, Sendable, Identifiable {
    case english = "en-US"
    case japanese = "ja-JP"

    var id: String { rawValue }

    var speechLocale: Locale {
        Locale(identifier: rawValue)
    }

    var translationSource: Locale.Language {
        switch self {
        case .english:
            Locale.Language(identifier: "en")
        case .japanese:
            Locale.Language(identifier: "ja")
        }
    }

    static let translationTarget = Locale.Language(identifier: "zh-Hans")
}
