import Foundation

protocol CaptionStoreProtocol: Sendable {
    func load() throws -> CaptionSnapshot?
    func save(_ snapshot: CaptionSnapshot) throws
    func clear() throws
}

enum CaptionStoreError: Error, Equatable {
    case appGroupUnavailable
}

final class CaptionStore: CaptionStoreProtocol, @unchecked Sendable {
    static let appGroupIdentifier = "group.com.xueqianzheng.LiveTranslate"

    private static let snapshotKey = "caption.snapshot"
    private let defaults: UserDefaults

    convenience init() throws {
        guard let defaults = UserDefaults(suiteName: Self.appGroupIdentifier) else {
            throw CaptionStoreError.appGroupUnavailable
        }
        self.init(defaults: defaults)
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func load() throws -> CaptionSnapshot? {
        guard let data = defaults.data(forKey: Self.snapshotKey) else {
            return nil
        }
        do {
            return try PropertyListDecoder().decode(CaptionSnapshot.self, from: data)
        } catch {
            defaults.removeObject(forKey: Self.snapshotKey)
            return nil
        }
    }

    func save(_ snapshot: CaptionSnapshot) throws {
        let data = try PropertyListEncoder().encode(snapshot)
        defaults.set(data, forKey: Self.snapshotKey)
    }

    func clear() throws {
        defaults.removeObject(forKey: Self.snapshotKey)
    }
}
