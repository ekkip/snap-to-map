import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Shared ImageIO HEIF/PNG settings for map tile persistence.
enum OverlayTileHEIFEncoding {
    static let defaultQuality: CGFloat = 0.78

    static func heifDestinationProperties(quality: CGFloat) -> [CFString: Any] {
        let q = min(max(quality, 0.1), 1)
        return [
            kCGImageDestinationLossyCompressionQuality: q,
        ]
    }

    static func encodeTileImageData(
        _ cgImage: CGImage,
        quality: CGFloat = defaultQuality,
        knownOpaque: Bool = false
    ) -> Data? {
        let imageForEncode = knownOpaque
            ? (rgbImageDroppingAlphaIfPresent(cgImage) ?? cgImage)
            : cgImageForLossyEncode(cgImage)
        let data = NSMutableData()
        if let heif = CGImageDestinationCreateWithData(data, UTType.heic.identifier as CFString, 1, nil) {
            let props = heifDestinationProperties(quality: quality)
            CGImageDestinationAddImage(heif, imageForEncode, props as CFDictionary)
            if CGImageDestinationFinalize(heif), (data as Data).count > 0 {
                return data as Data
            }
        }
        let pngData = NSMutableData()
        guard let png = CGImageDestinationCreateWithData(pngData, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(png, imageForEncode, nil)
        guard CGImageDestinationFinalize(png) else { return nil }
        return pngData as Data
    }

    /// Opaque RGBA bitmaps encoded as HEIF with alpha cost ~2× decode RAM; strip alpha when every pixel is opaque.
    private static func cgImageForLossyEncode(_ image: CGImage) -> CGImage {
        guard cgImageHasAnyTransparency(image) else {
            return rgbImageDroppingAlphaIfPresent(image) ?? image
        }
        return image
    }

    private static func cgImageHasAnyTransparency(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return false
        default:
            break
        }
        guard let providerData = image.dataProvider?.data,
              let ptr = CFDataGetBytePtr(providerData) else {
            return true
        }
        let bytesPerPixel = max(1, image.bitsPerPixel / 8)
        guard bytesPerPixel >= 4 else { return true }
        let alphaOffset: Int
        switch image.alphaInfo {
        case .first, .premultipliedFirst, .noneSkipFirst:
            alphaOffset = 0
        case .last, .premultipliedLast, .noneSkipLast:
            alphaOffset = bytesPerPixel - 1
        default:
            return true
        }
        let stride = image.bytesPerRow
        let w = image.width
        let h = image.height
        guard w > 0, h > 0 else { return false }
        func alphaAt(x: Int, y: Int) -> UInt8 {
            ptr[y * stride + x * bytesPerPixel + alphaOffset]
        }
        for x in 0..<w {
            if alphaAt(x: x, y: 0) < 255 || alphaAt(x: x, y: h - 1) < 255 { return true }
        }
        for y in 0..<h {
            if alphaAt(x: 0, y: y) < 255 || alphaAt(x: w - 1, y: y) < 255 { return true }
        }
        return false
    }

    private static func rgbImageDroppingAlphaIfPresent(_ image: CGImage) -> CGImage? {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return image
        default:
            break
        }
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
}
