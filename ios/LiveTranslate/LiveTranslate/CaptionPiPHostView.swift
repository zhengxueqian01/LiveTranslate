@preconcurrency import AVFoundation
import SwiftUI
import UIKit

@MainActor
final class CaptionPiPHostView: UIView {
    var didMount: (() -> Void)?
    private var hasNotifiedMount = false

    override class var layerClass: AnyClass {
        AVSampleBufferDisplayLayer.self
    }

    var captionDisplayLayer: AVSampleBufferDisplayLayer {
        layer as! AVSampleBufferDisplayLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        captionDisplayLayer.videoGravity = .resizeAspect
        backgroundColor = .black
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        captionDisplayLayer.videoGravity = .resizeAspect
        backgroundColor = .black
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        notifyIfMounted()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        notifyIfMounted()
    }

    private func notifyIfMounted() {
        guard !hasNotifiedMount,
              window != nil,
              bounds.width > 0,
              bounds.height > 0 else {
            return
        }
        hasNotifiedMount = true
        didMount?()
    }
}

@MainActor
struct CaptionPiPHostViewRepresentable: UIViewRepresentable {
    let hostView: CaptionPiPHostView

    func makeUIView(context: Context) -> CaptionPiPHostView {
        hostView
    }

    func updateUIView(_ uiView: CaptionPiPHostView, context: Context) {}
}
