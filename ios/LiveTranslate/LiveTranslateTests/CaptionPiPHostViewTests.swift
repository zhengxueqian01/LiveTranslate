import UIKit
import XCTest
@testable import LiveTranslate

@MainActor
final class CaptionPiPHostViewTests: XCTestCase {
    func testControllerUsesHostBackingLayerAsPictureInPictureSource() {
        let controller = CaptionPiPController()

        XCTAssertTrue(controller.hostView.captionDisplayLayer === controller.displayLayer)
    }

    func testHostNotifiesMountOnlyAfterWindowAttachmentAndOnlyOnce() {
        let hostView = CaptionPiPHostView()
        var mountCount = 0
        hostView.didMount = {
            mountCount += 1
        }
        hostView.frame = CGRect(x: 0, y: 0, width: 300, height: 100)
        hostView.layoutIfNeeded()

        XCTAssertEqual(mountCount, 0)

        let window = UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        let rootViewController = UIViewController()
        window.rootViewController = rootViewController
        window.makeKeyAndVisible()
        rootViewController.view.addSubview(hostView)
        rootViewController.view.layoutIfNeeded()
        hostView.layoutIfNeeded()

        XCTAssertEqual(hostView.captionDisplayLayer.bounds.size, CGSize(width: 300, height: 100))
        XCTAssertEqual(mountCount, 1)

        hostView.setNeedsLayout()
        hostView.layoutIfNeeded()
        XCTAssertEqual(mountCount, 1)
    }
}
