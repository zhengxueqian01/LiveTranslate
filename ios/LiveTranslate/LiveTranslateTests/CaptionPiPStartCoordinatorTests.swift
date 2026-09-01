import XCTest
@testable import LiveTranslate

final class CaptionPiPStartCoordinatorTests: XCTestCase {
    func testPendingRequestStartsAfterFirstFrameBecomesPossible() {
        var coordinator = CaptionPiPStartCoordinator()

        XCTAssertFalse(coordinator.requestStart(isPossible: false))
        XCTAssertEqual(coordinator.state, .pending)

        XCTAssertTrue(coordinator.didEnqueueFrame(isPossible: true))
        XCTAssertEqual(coordinator.state, .active)
    }

    func testFailedStartExposesUserVisibleMessage() {
        var coordinator = CaptionPiPStartCoordinator()

        _ = coordinator.requestStart(isPossible: true)
        _ = coordinator.didEnqueueFrame(isPossible: true)
        coordinator.didFailToStart(errorDescription: "系统拒绝启动")

        XCTAssertEqual(coordinator.state, .failed("画中画字幕启动失败：系统拒绝启动"))
        XCTAssertEqual(coordinator.state.statusMessage, "画中画字幕启动失败：系统拒绝启动")
    }
}
