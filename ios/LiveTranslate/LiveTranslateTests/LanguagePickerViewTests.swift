import XCTest
@testable import LiveTranslate

final class LanguagePickerViewTests: XCTestCase {
    func testFilterMatchesLocalizedNameAndStableIdentifier() {
        let items = [
            LanguagePickerItem(id: "ja-JP", title: "日语（日本）"),
            LanguagePickerItem(id: "en-US", title: "英语（美国）")
        ]

        XCTAssertEqual(LanguagePickerFilter.filter(items, query: "日语").map(\.id), ["ja-JP"])
        XCTAssertEqual(LanguagePickerFilter.filter(items, query: "en-US").map(\.id), ["en-US"])
        XCTAssertEqual(LanguagePickerFilter.filter(items, query: "").count, 2)
    }
}
