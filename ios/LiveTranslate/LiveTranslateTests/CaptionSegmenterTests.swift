import XCTest
@testable import LiveTranslate

final class CaptionSegmenterTests: XCTestCase {
    func testFinalResultImmediatelyCreatesTranslationCandidate() {
        var segmenter = CaptionSegmenter(minimumIntervalMilliseconds: 800)

        let update = segmenter.ingest(
            text: "Hello world.",
            isFinal: true,
            timestampMilliseconds: 100
        )

        XCTAssertEqual(update?.displayText, "Hello world.")
        XCTAssertEqual(update?.translationCandidate?.text, "Hello world.")
        XCTAssertEqual(update?.translationCandidate?.revision, 1)
    }

    func testGrowingPartialIsThrottledUntilIntervalExpires() {
        var segmenter = CaptionSegmenter(minimumIntervalMilliseconds: 800)

        _ = segmenter.ingest(text: "日本", isFinal: false, timestampMilliseconds: 0)
        let early = segmenter.ingest(
            text: "日本語の動画",
            isFinal: false,
            timestampMilliseconds: 300
        )
        let ready = segmenter.ingest(
            text: "日本語の動画です",
            isFinal: false,
            timestampMilliseconds: 900
        )

        XCTAssertEqual(early?.displayText, "日本語の動画")
        XCTAssertNil(early?.translationCandidate)
        XCTAssertEqual(ready?.translationCandidate?.text, "日本語の動画です")
        XCTAssertEqual(ready?.translationCandidate?.revision, 1)
    }

    func testFinalDuplicateOfUntranslatedPartialCreatesCandidate() {
        var segmenter = CaptionSegmenter(minimumIntervalMilliseconds: 800)

        _ = segmenter.ingest(text: "short", isFinal: false, timestampMilliseconds: 0)
        let final = segmenter.ingest(
            text: "short",
            isFinal: true,
            timestampMilliseconds: 100
        )

        XCTAssertEqual(final?.translationCandidate?.text, "short")
        XCTAssertEqual(final?.translationCandidate?.revision, 1)
    }

    func testEmptyAndRepeatedPartialTextAreIgnored() {
        var segmenter = CaptionSegmenter(minimumIntervalMilliseconds: 800)

        XCTAssertNil(segmenter.ingest(text: "   ", isFinal: false, timestampMilliseconds: 0))
        XCTAssertNotNil(segmenter.ingest(text: "hello", isFinal: false, timestampMilliseconds: 10))
        XCTAssertNil(segmenter.ingest(text: " hello ", isFinal: false, timestampMilliseconds: 20))
    }
}
