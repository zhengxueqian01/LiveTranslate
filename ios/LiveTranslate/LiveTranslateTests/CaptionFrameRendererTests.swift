import CoreVideo
import XCTest
@testable import LiveTranslate

final class CaptionFrameRendererTests: XCTestCase {
    func testRendererPlacesSourceTextInUpperHalfOfPixelBuffer() throws {
        let snapshot = CaptionSnapshot(
            revision: 1,
            sourceText: "H",
            translatedText: "",
            phase: .translating,
            errorMessage: nil,
            updatedAt: .now
        )
        let buffer = try CaptionFrameRenderer().makePixelBuffer(
            snapshot: snapshot,
            size: CGSize(width: 960, height: 320)
        )

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let brightPixelCounts = try countBrightPixels(in: buffer)

        XCTAssertGreaterThan(brightPixelCounts.upperHalf, 0)
        XCTAssertGreaterThan(brightPixelCounts.upperHalf, brightPixelCounts.lowerHalf)
    }

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

    private func countBrightPixels(in buffer: CVPixelBuffer) throws -> (
        upperHalf: Int,
        lowerHalf: Int
    ) {
        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else {
            throw RendererTestError.missingPixelBufferBaseAddress
        }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let pixels = baseAddress.assumingMemoryBound(to: UInt8.self)
        var upperHalf = 0
        var lowerHalf = 0

        for y in 0 ..< height {
            for x in 0 ..< width {
                let offset = y * bytesPerRow + x * 4
                let isBright = pixels[offset] > 220
                    && pixels[offset + 1] > 220
                    && pixels[offset + 2] > 220
                guard isBright else {
                    continue
                }
                if y < height / 2 {
                    upperHalf += 1
                } else {
                    lowerHalf += 1
                }
            }
        }
        return (upperHalf, lowerHalf)
    }
}

private enum RendererTestError: Error {
    case missingPixelBufferBaseAddress
}
