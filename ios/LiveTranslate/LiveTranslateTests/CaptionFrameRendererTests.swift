import CoreVideo
import XCTest
@testable import LiveTranslate

final class CaptionFrameRendererTests: XCTestCase {
    func testRendererCreatesRequestedPixelBuffer() throws {
        let snapshot = CaptionSnapshot(
            revision: 1,
            sourceText: "Hello",
            translatedText: "你好",
            phase: .translating,
            errorMessage: nil,
            updatedAt: .now
        )

        let buffer = try CaptionFrameRenderer().makePixelBuffer(
            snapshot: snapshot,
            size: CGSize(width: 960, height: 320)
        )

        XCTAssertEqual(CVPixelBufferGetWidth(buffer), 960)
        XCTAssertEqual(CVPixelBufferGetHeight(buffer), 320)
    }
}
