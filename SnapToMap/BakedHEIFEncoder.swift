import CoreGraphics
import CoreImage
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Lossy **HEIC** for all overlay blobs persisted from this app (**source** + **baked**), via **ImageIO** (hardware-accelerated on Apple GPUs).
enum BakedHEIFEncoder {

    private static let ciContextForOrientation = CIContext(options: [.highQualityDownsample: true])

    /// `quality` is **0…1** (`kCGImageDestinationLossyCompressionQuality`). Preserves alpha when the image has it.
    static func encodeLossyWithAlpha(image: UIImage, quality: CGFloat) -> Data? {
        encodeLossy(image: image, quality: quality, preserveAlpha: true)
    }

    /// `quality` is **0…1** (`kCGImageDestinationLossyCompressionQuality`).
    /// Set `preserveAlpha` to `false` for opaque-only payloads to avoid alpha-channel memory overhead.
    static func encodeLossy(image: UIImage, quality: CGFloat, preserveAlpha: Bool) -> Data? {
        guard let cgImage = normalizedCGImageForEncode(from: image) else { return nil }
        let imageForEncode: CGImage
        if preserveAlpha {
            imageForEncode = cgImage
        } else {
            imageForEncode = rgbImageDroppingAlphaIfPresent(cgImage) ?? cgImage
        }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data,
            UTType.heic.identifier as CFString,
            1,
            nil
        ) else { return nil }
        let q = min(max(quality, 0.05), 1.0)
        let props: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: q,
        ]
        CGImageDestinationAddImage(dest, imageForEncode, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        guard (data as Data).count > 0 else { return nil }
        return data as Data
    }

    private static func rgbImageDroppingAlphaIfPresent(_ image: CGImage) -> CGImage? {
        let alphaInfo = image.alphaInfo
        let alreadyOpaque = alphaInfo == .none || alphaInfo == .noneSkipFirst || alphaInfo == .noneSkipLast
        if alreadyOpaque { return image }
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil,
                  width: image.width,
                  height: image.height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: cs,
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
    }

    private static func normalizedCGImageForEncode(from image: UIImage) -> CGImage? {
        if image.imageOrientation == .up, let cg = image.cgImage { return cg }
        guard let ci = CIImage(image: image) else { return nil }
        let oriented = ci.oriented(forExifOrientation: exifOrientation(for: image.imageOrientation))
        let extent = oriented.extent.integral
        guard extent.width >= 1, extent.height >= 1 else { return nil }
        return Self.ciContextForOrientation.createCGImage(oriented, from: extent)
    }

    private static func exifOrientation(for o: UIImage.Orientation) -> Int32 {
        switch o {
        case .up: return 1
        case .upMirrored: return 2
        case .down: return 3
        case .downMirrored: return 4
        case .leftMirrored: return 5
        case .right: return 6
        case .rightMirrored: return 7
        case .left: return 8
        @unknown default: return 1
        }
    }
}
