@preconcurrency import AVFoundation
import Foundation

@MainActor
protocol CaptionPiPAudioSessionPreparing: AnyObject {
    func prepareForPictureInPicture() throws
}

@MainActor
final class SystemCaptionPiPAudioSessionPreparer: CaptionPiPAudioSessionPreparing {
    func prepareForPictureInPicture() throws {
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
        try audioSession.setActive(true)
    }
}

@MainActor
final class CaptionPiPStartupCoordinator {
    private let audioSession: any CaptionPiPAudioSessionPreparing
    private let startPictureInPicture: () -> Void
    private let stateDidChange: (CaptionPiPStartState) -> Void
    private var isPossible = false
    private var timeoutTask: Task<Void, Never>?

    private(set) var isConfigured = false
    private(set) var state: CaptionPiPStartState = .idle

    init(
        audioSession: any CaptionPiPAudioSessionPreparing,
        startPictureInPicture: @escaping () -> Void,
        stateDidChange: @escaping (CaptionPiPStartState) -> Void = { _ in }
    ) {
        self.audioSession = audioSession
        self.startPictureInPicture = startPictureInPicture
        self.stateDidChange = stateDidChange
    }

    func hostDidMount() -> Bool {
        guard !isConfigured else {
            return false
        }
        isConfigured = true
        return true
    }

    func requestStart() {
        guard isConfigured else {
            fail(with: "字幕预览尚未准备好。")
            return
        }

        do {
            try audioSession.prepareForPictureInPicture()
        } catch {
            fail(with: "音频会话准备失败：\(error.localizedDescription)")
            return
        }

        setState(.pending)
        startIfPossible()
    }

    func readinessDidChange(_ isPossible: Bool) {
        self.isPossible = isPossible
        startIfPossible()
    }

    func timeoutElapsed() {
        guard state == .pending else {
            return
        }
        fail(with: "等待系统准备超时，请重试。")
    }

    func didFailToStart(errorDescription: String) {
        fail(with: errorDescription)
    }

    func stop() {
        timeoutTask?.cancel()
        timeoutTask = nil
        setState(.idle)
    }

    private func startIfPossible() {
        guard state == .pending else {
            return
        }
        guard isPossible else {
            scheduleTimeout()
            return
        }
        timeoutTask?.cancel()
        timeoutTask = nil
        setState(.active)
        startPictureInPicture()
    }

    private func scheduleTimeout() {
        guard timeoutTask == nil else {
            return
        }
        timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(5))
            } catch is CancellationError {
                return
            } catch {
                return
            }
            guard !Task.isCancelled else {
                return
            }
            self?.timeoutElapsed()
        }
    }

    private func fail(with reason: String) {
        timeoutTask?.cancel()
        timeoutTask = nil
        setState(.failed("画中画字幕启动失败：\(reason)"))
    }

    private func setState(_ state: CaptionPiPStartState) {
        self.state = state
        stateDidChange(state)
    }

    deinit {
        timeoutTask?.cancel()
    }
}
