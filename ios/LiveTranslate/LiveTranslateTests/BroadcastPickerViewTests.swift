import ReplayKit
import SwiftUI
import UIKit
import XCTest

@testable import LiveTranslate

@MainActor
final class BroadcastPickerViewTests: XCTestCase {
    func testPickerStartsWithDisplayedControlBoundsAndBroadcastConfiguration() throws {
        let host = UIHostingController(
            rootView: BroadcastPickerView().frame(width: 52, height: 52)
        )
        let windowScene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.first as? UIWindowScene
        )
        let window = UIWindow(windowScene: windowScene)
        window.frame = CGRect(x: 0, y: 0, width: 52, height: 52)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        host.view.layoutIfNeeded()

        let picker = try XCTUnwrap(findBroadcastPicker(in: host.view))

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

        if let systemButton = findSystemButton(in: picker) {
            XCTAssertTrue(systemButton.bounds.width.isFinite)
            XCTAssertTrue(systemButton.bounds.height.isFinite)
            XCTAssertGreaterThan(systemButton.bounds.width, 0)
            XCTAssertGreaterThan(systemButton.bounds.height, 0)
        }
    }

    private func findBroadcastPicker(in view: UIView) -> RPSystemBroadcastPickerView? {
        if let picker = view as? RPSystemBroadcastPickerView {
            return picker
        }

        for subview in view.subviews {
            if let picker = findBroadcastPicker(in: subview) {
                return picker
            }
        }

        return nil
    }

    private func findSystemButton(in view: UIView) -> UIButton? {
        for subview in view.subviews {
            if let button = subview as? UIButton {
                return button
            }

            if let button = findSystemButton(in: subview) {
                return button
            }
        }

        return nil
    }
}
