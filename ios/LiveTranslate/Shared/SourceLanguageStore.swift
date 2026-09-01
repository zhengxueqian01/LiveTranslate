import Foundation

final class SourceLanguageStore: @unchecked Sendable {
    static let key = "source.language"

    private let defaults: UserDefaults

    convenience init() throws {
        guard let defaults = UserDefaults(suiteName: CaptionStore.appGroupIdentifier) else {
            throw CaptionStoreError.appGroupUnavailable
        }
        self.init(defaults: defaults)
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func load() -> SourceLanguage? {
        guard let rawValue = defaults.string(forKey: Self.key) else {
            return nil
        }
        return SourceLanguage(rawValue: rawValue)
    }

    func save(_ source: SourceLanguage) {
        defaults.set(source.rawValue, forKey: Self.key)
    }
}
