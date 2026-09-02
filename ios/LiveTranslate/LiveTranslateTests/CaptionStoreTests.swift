import Foundation
import XCTest
@testable import LiveTranslate

final class CaptionStoreTests: XCTestCase {
    func testSnapshotRoundTripsThroughIsolatedDefaults() throws {
        let suiteName = "CaptionStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = CaptionStore(defaults: defaults)
        let snapshot = CaptionSnapshot(
            revision: 7,
            sourceText: "Hello",
            translatedText: "你好",
            phase: .translating,
            errorMessage: nil,
            updatedAt: Date(timeIntervalSince1970: 1)
        )

        try store.save(snapshot)

        XCTAssertEqual(try store.load(), snapshot)

        try store.clear()

        XCTAssertNil(try store.load())
    }

    func testCorruptSnapshotIsDiscardedAsDisposableCache() throws {
        let suiteName = "CaptionStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Data([0xFF, 0x00, 0xAA]), forKey: "caption.snapshot")

        let store = CaptionStore(defaults: defaults)

        XCTAssertNil(try store.load())
        XCTAssertNil(defaults.object(forKey: "caption.snapshot"))
    }
}
