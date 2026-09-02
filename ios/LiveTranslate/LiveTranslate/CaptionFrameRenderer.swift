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
        let verticalInset: CGFloat = 20
        let gap: CGFloat = 12
        let captionHeight = (size.height - verticalInset * 2 - gap) / 2
        let captionWidth = size.width - inset * 2
        let sourceRect = CGRect(
            x: inset,
            y: verticalInset,
            width: captionWidth,
            height: captionHeight
        )
        let translationRect = CGRect(
            x: inset,
            y: verticalInset + captionHeight + gap,
            width: captionWidth,
            height: captionHeight
        )
        let sourceColor = snapshot.phase == .failed ? UIColor.systemYellow : UIColor.white
        let translationColor = snapshot.phase == .failed ? UIColor.systemRed : UIColor.white

        context.saveGState()
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(context)
        (snapshot.sourceText as NSString).draw(
            in: sourceRect,
            withAttributes: fittedAttributes(
                for: snapshot.sourceText,
                in: sourceRect,
                preferredFontSize: 42,
                minimumFontSize: 14,
                weight: .semibold,
                color: sourceColor
            )
        )
        let translation = displayedTranslation(for: snapshot)
        (translation as NSString).draw(
            in: translationRect,
            withAttributes: fittedAttributes(
                for: translation,
                in: translationRect,
                preferredFontSize: 46,
                minimumFontSize: 16,
                weight: .bold,
                color: translationColor
            )
        )
        UIGraphicsPopContext()
        context.restoreGState()
    }

    private func fittedAttributes(
        for text: String,
        in rect: CGRect,
        preferredFontSize: CGFloat,
        minimumFontSize: CGFloat,
        weight: UIFont.Weight,
        color: UIColor
    ) -> [NSAttributedString.Key: Any] {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping

        func attributes(fontSize: CGFloat) -> [NSAttributedString.Key: Any] {
            [
                .font: UIFont.systemFont(ofSize: fontSize, weight: weight),
                .foregroundColor: color,
                .paragraphStyle: paragraphStyle
            ]
        }

        var lowerBound = Int(minimumFontSize.rounded(.up))
        var upperBound = Int(preferredFontSize.rounded(.down))
        var fittedFontSize = lowerBound
        let measurementSize = CGSize(
            width: rect.width,
            height: .greatestFiniteMagnitude
        )
        while lowerBound <= upperBound {
            let candidate = (lowerBound + upperBound) / 2
            let candidateAttributes = attributes(fontSize: CGFloat(candidate))
            let bounds = (text as NSString).boundingRect(
                with: measurementSize,
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: candidateAttributes,
                context: nil
            )
            if ceil(bounds.width) <= rect.width, ceil(bounds.height) <= rect.height {
                fittedFontSize = candidate
                lowerBound = candidate + 1
            } else {
                upperBound = candidate - 1
            }
        }
        return attributes(fontSize: CGFloat(fittedFontSize))
    }

    private func displayedTranslation(for snapshot: CaptionSnapshot) -> String {
        if snapshot.phase == .failed, let errorMessage = snapshot.errorMessage {
            return errorMessage
        }
        return snapshot.translatedText
    }
}
