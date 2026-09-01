@preconcurrency import AVFoundation
import SwiftUI
import UIKit

@MainActor
final class CaptionPiPHostView: UIView {
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
}

@MainActor
struct CaptionPiPHostViewRepresentable: UIViewRepresentable {
    let hostView: CaptionPiPHostView

    func makeUIView(context: Context) -> CaptionPiPHostView {
        hostView
    }

    func updateUIView(_ uiView: CaptionPiPHostView, context: Context) {}
}
