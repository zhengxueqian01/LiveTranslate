import ReplayKit
import XCTest

@testable import LiveTranslate

@MainActor
final class BroadcastPickerViewTests: XCTestCase {
    func testMakePickerStartsWithDisplayedControlBoundsAndBroadcastConfiguration() {
        let picker = BroadcastPickerView.makePicker()

        XCTAssertEqual(picker.bounds.size, CGSize(width: 52, height: 52))
        XCTAssertTrue(picker.bounds.width.isFinite)
        XCTAssertTrue(picker.bounds.height.isFinite)
        XCTAssertGreaterThan(picker.bounds.width, 0)
        XCTAssertGreaterThan(picker.bounds.height, 0)
        XCTAssertEqual(
            picker.preferredExtension,
            "com.xueqianzheng.LiveTranslate.BroadcastExtension"
        )
        XCTAssertFalse(picker.showsMicrophoneButton)
    }
}
