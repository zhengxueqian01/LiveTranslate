import CoreGraphics
import CoreVideo
import UIKit

enum CaptionFrameRendererError: Error, Equatable {
    case invalidSize
    case pixelBufferCreationFailed(OSStatus)
    case bitmapContextCreationFailed
}

struct CaptionFrameRenderer {
    func makePixelBuffer(
        snapshot: CaptionSnapshot,
        size: CGSize
    ) throws -> CVPixelBuffer {
        guard size.width.isFinite,
              size.height.isFinite,
              size.width > 0,
              size.height > 0,
              size.width <= CGFloat(Int32.max),
              size.height <= CGFloat(Int32.max) else {
            throw CaptionFrameRendererError.invalidSize
        }

        let width = Int(size.width.rounded(.down))
        let height = Int(size.height.rounded(.down))
        guard width > 0, height > 0 else {
            throw CaptionFrameRendererError.invalidSize
        }

        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            [
                kCVPixelBufferCGImageCompatibilityKey: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [:]
            ] as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw CaptionFrameRendererError.pixelBufferCreationFailed(status)
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer),
              let context = CGContext(
                  data: baseAddress,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              ) else {
            throw CaptionFrameRendererError.bitmapContextCreationFailed
        }

        draw(snapshot: snapshot, in: context, size: CGSize(width: width, height: height))
        return pixelBuffer
    }

    private func draw(snapshot: CaptionSnapshot, in context: CGContext, size: CGSize) {
        context.setFillColor(UIColor.black.withAlphaComponent(0.78).cgColor)
        context.fill(CGRect(origin: .zero, size: size))

        let inset: CGFloat = 32
        let sourceRect = CGRect(x: inset, y: 40, width: size.width - inset * 2, height: 100)
        let translationRect = CGRect(x: inset, y: 170, width: size.width - inset * 2, height: 100)
        let sourceColor = snapshot.phase == .failed ? UIColor.systemYellow : UIColor.white
        let translationColor = snapshot.phase == .failed ? UIColor.systemRed : UIColor.white

        UIGraphicsPushContext(context)
        (snapshot.sourceText as NSString).draw(
            in: sourceRect,
            withAttributes: [
                .font: UIFont.systemFont(ofSize: 42, weight: .semibold),
                .foregroundColor: sourceColor
            ]
        )
        (displayedTranslation(for: snapshot) as NSString).draw(
            in: translationRect,
            withAttributes: [
                .font: UIFont.systemFont(ofSize: 46, weight: .bold),
                .foregroundColor: translationColor
            ]
        )
        UIGraphicsPopContext()
    }

    private func displayedTranslation(for snapshot: CaptionSnapshot) -> String {
        if snapshot.phase == .failed, let errorMessage = snapshot.errorMessage {
            return errorMessage
        }
        return snapshot.translatedText
    }
}
