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
}
