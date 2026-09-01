import UIKit
import XCTest
@testable import LiveTranslate

@MainActor
final class CaptionPiPHostViewTests: XCTestCase {
    func testControllerUsesHostBackingLayerAsPictureInPictureSource() {
        let controller = CaptionPiPController()

        XCTAssertTrue(controller.hostView.captionDisplayLayer === controller.displayLayer)
    }

    func testHostBackingLayerTracksNonzeroLaidOutBounds() {
        let hostView = CaptionPiPHostView()
        hostView.frame = CGRect(x: 0, y: 0, width: 300, height: 100)
        hostView.layoutIfNeeded()

        XCTAssertEqual(hostView.captionDisplayLayer.bounds.size, CGSize(width: 300, height: 100))
    }
}
