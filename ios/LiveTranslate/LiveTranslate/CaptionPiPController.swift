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

@MainActor
final class CaptionPiPController: NSObject, ObservableObject {
    private let renderer: CaptionFrameRenderer
    private let renderSize: CGSize
    private let audioSession: any CaptionPiPAudioSessionPreparing
    let hostView: CaptionPiPHostView
    var displayLayer: AVSampleBufferDisplayLayer {
        hostView.captionDisplayLayer
    }
    private var pictureInPictureController: AVPictureInPictureController?
    private var readinessObservation: NSKeyValueObservation?
    private var lastRenderedRevision: UInt64?
    private var startupCoordinator: CaptionPiPStartupCoordinator!

    @Published private(set) var startState: CaptionPiPStartState = .idle
    @Published private(set) var isReadyForPictureInPicture = false
    var didStop: (() -> Void)?

    init(
        renderer: CaptionFrameRenderer = CaptionFrameRenderer(),
        renderSize: CGSize = CGSize(width: 960, height: 320),
        audioSession: any CaptionPiPAudioSessionPreparing = SystemCaptionPiPAudioSessionPreparer()
    ) {
        self.renderer = renderer
        self.renderSize = renderSize
        self.audioSession = audioSession
        hostView = CaptionPiPHostView()
        super.init()
        startupCoordinator = CaptionPiPStartupCoordinator(
            audioSession: audioSession,
            startPictureInPicture: { [weak self] in
                self?.pictureInPictureController?.startPictureInPicture()
            },
            stateDidChange: { [weak self] state in
                self?.startState = state
            }
        )
        hostView.didMount = { [weak self] in
            self?.hostViewDidMount()
        }
    }

    var isSupported: Bool {
        AVPictureInPictureController.isPictureInPictureSupported()
    }

    func start() {
        installReadinessObservation()
        startupCoordinator.requestStart()
    }

    func stop() {
        pictureInPictureController?.stopPictureInPicture()
        readinessObservation?.invalidate()
        readinessObservation = nil
        resetForNextStart()
    }

    func hostViewDidMount() {
        guard startupCoordinator.hostDidMount() else {
            return
        }
        guard isSupported else {
            startupCoordinator.didFailToStart(errorDescription: "当前设备不支持画中画字幕。")
            return
        }

        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: displayLayer,
            playbackDelegate: self
        )
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        pictureInPictureController = controller
        isReadyForPictureInPicture = true
        installReadinessObservation()
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
            if startupCoordinator.state == .pending {
                startupCoordinator.didFailToStart(errorDescription: "字幕画面准备失败。")
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

    private func installReadinessObservation() {
        guard let pictureInPictureController, readinessObservation == nil else {
            return
        }
        readinessObservation = pictureInPictureController.observe(
            \.isPictureInPicturePossible,
            options: [.initial, .new]
        ) { [weak self] controller, _ in
            Task { @MainActor [weak self] in
                self?.startupCoordinator.readinessDidChange(
                    controller.isPictureInPicturePossible
                )
            }
        }
    }

    private func resetForNextStart() {
        lastRenderedRevision = nil
        startupCoordinator.stop()
    }

    deinit {
        readinessObservation?.invalidate()
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
        readinessObservation?.invalidate()
        readinessObservation = nil
        resetForNextStart()
        didStop?()
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        startupCoordinator.didFailToStart(errorDescription: error.localizedDescription)
    }
}
