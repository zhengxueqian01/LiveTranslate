@preconcurrency import AVFoundation
@preconcurrency import AVKit
import CoreMedia
import Foundation

@MainActor
final class CaptionPiPController: NSObject {
    private let renderer: CaptionFrameRenderer
    private let renderSize: CGSize
    private let displayLayer = AVSampleBufferDisplayLayer()
    private var pictureInPictureController: AVPictureInPictureController?
    private var lastRenderedRevision: UInt64?

    var didStop: (() -> Void)?

    init(
        renderer: CaptionFrameRenderer = CaptionFrameRenderer(),
        renderSize: CGSize = CGSize(width: 960, height: 320)
    ) {
        self.renderer = renderer
        self.renderSize = renderSize
        super.init()

        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            return
        }

        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: displayLayer,
            playbackDelegate: self
        )
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        pictureInPictureController = controller
    }

    var isSupported: Bool {
        pictureInPictureController != nil
    }

    func start() {
        pictureInPictureController?.startPictureInPicture()
    }

    func stop() {
        pictureInPictureController?.stopPictureInPicture()
    }

    func render(_ snapshot: CaptionSnapshot) {
        guard lastRenderedRevision.map({ snapshot.revision > $0 }) ?? true else {
            return
        }

        do {
            let pixelBuffer = try renderer.makePixelBuffer(snapshot: snapshot, size: renderSize)
            try enqueue(pixelBuffer)
            lastRenderedRevision = snapshot.revision
        } catch {
            displayLayer.flushAndRemoveImage()
        }
    }

    private func enqueue(_ pixelBuffer: CVPixelBuffer) throws {
        var formatDescription: CMVideoFormatDescription?
        let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
        guard formatStatus == noErr, let formatDescription else {
            throw CaptionPiPControllerError.formatDescriptionCreationFailed(formatStatus)
        }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer else {
            throw CaptionPiPControllerError.sampleBufferCreationFailed(sampleStatus)
        }

        if displayLayer.status == .failed {
            displayLayer.flush()
        }
        displayLayer.enqueue(sampleBuffer)
    }
}

private enum CaptionPiPControllerError: Error {
    case formatDescriptionCreationFailed(OSStatus)
    case sampleBufferCreationFailed(OSStatus)
}

extension CaptionPiPController: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        setPlaying playing: Bool
    ) {}

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> CMTimeRange {
        CMTimeRange(start: .zero, duration: .positiveInfinity)
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        false
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {}

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime
    ) async {}

}

extension CaptionPiPController: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        didStop?()
    }
}
