@preconcurrency import AVFoundation
@preconcurrency import AVKit
import Combine
import CoreMedia
import Foundation

enum CaptionPiPStartState: Equatable {
    case idle
    case pending
    case active
    case failed(String)

    var statusMessage: String? {
        switch self {
        case .idle, .active:
            nil
        case .pending:
            "正在等待字幕画面以打开画中画。"
        case .failed(let message):
            message
        }
    }

    var isFailure: Bool {
        if case .failed = self {
            return true
        }
        return false
    }
}

struct CaptionPiPStartCoordinator {
    private(set) var state: CaptionPiPStartState = .idle
    private var hasEnqueuedFrame = false

    mutating func requestStart(isPossible: Bool) -> Bool {
        state = .pending
        return startIfReady(isPossible: isPossible)
    }

    mutating func didEnqueueFrame(isPossible: Bool) -> Bool {
        hasEnqueuedFrame = true
        return startIfReady(isPossible: isPossible)
    }

    mutating func didFailToStart(errorDescription: String) {
        state = .failed("画中画字幕启动失败：\(errorDescription)")
    }

    mutating func stop() {
        state = .idle
        hasEnqueuedFrame = false
    }

    private mutating func startIfReady(isPossible: Bool) -> Bool {
        guard state == .pending, hasEnqueuedFrame, isPossible else {
            return false
        }
        state = .active
        return true
    }
}

@MainActor
final class CaptionPiPController: NSObject, ObservableObject {
    private let renderer: CaptionFrameRenderer
    private let renderSize: CGSize
    let hostView: CaptionPiPHostView
    var displayLayer: AVSampleBufferDisplayLayer {
        hostView.captionDisplayLayer
    }
    private var pictureInPictureController: AVPictureInPictureController?
    private var lastRenderedRevision: UInt64?
    private var startCoordinator = CaptionPiPStartCoordinator()

    @Published private(set) var startState: CaptionPiPStartState = .idle
    var didStop: (() -> Void)?

    init(
        renderer: CaptionFrameRenderer = CaptionFrameRenderer(),
        renderSize: CGSize = CGSize(width: 960, height: 320)
    ) {
        self.renderer = renderer
        self.renderSize = renderSize
        hostView = CaptionPiPHostView()
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
        guard let pictureInPictureController else {
            startCoordinator.didFailToStart(errorDescription: "当前设备不支持画中画字幕。")
            updateStartState()
            return
        }

        let shouldStart = startCoordinator.requestStart(
            isPossible: pictureInPictureController.isPictureInPicturePossible
        )
        updateStartState()
        if shouldStart {
            pictureInPictureController.startPictureInPicture()
        }
    }

    func stop() {
        pictureInPictureController?.stopPictureInPicture()
        resetForNextStart()
    }

    func render(_ snapshot: CaptionSnapshot) {
        guard lastRenderedRevision.map({ snapshot.revision > $0 }) ?? true else {
            return
        }

        do {
            let pixelBuffer = try renderer.makePixelBuffer(snapshot: snapshot, size: renderSize)
            try enqueue(pixelBuffer)
            lastRenderedRevision = snapshot.revision
            if let pictureInPictureController,
               startCoordinator.didEnqueueFrame(
                   isPossible: pictureInPictureController.isPictureInPicturePossible
               ) {
                updateStartState()
                pictureInPictureController.startPictureInPicture()
            } else {
                updateStartState()
            }
        } catch {
            displayLayer.flushAndRemoveImage()
            if startCoordinator.state == .pending {
                startCoordinator.didFailToStart(errorDescription: "字幕画面准备失败。")
                updateStartState()
            }
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

    private func updateStartState() {
        startState = startCoordinator.state
    }

    private func resetForNextStart() {
        lastRenderedRevision = nil
        startCoordinator.stop()
        updateStartState()
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
        resetForNextStart()
        didStop?()
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        startCoordinator.didFailToStart(errorDescription: error.localizedDescription)
        updateStartState()
    }
}
