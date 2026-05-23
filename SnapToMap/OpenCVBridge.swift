import CoreGraphics
import Foundation
import UIKit

/// Swift façade over **`STMOpenCVBridge`** (Objective-C++ / OpenCV). App code calls into this type only.
///
/// **Note:** Offline pyramid tiles use the ImageIO + Core Image path (`OverlayTileRenderer`). This bridge is
/// **kept linked** for upcoming implementation steps (e.g. alternate warp / `pyrDown` experiments) — do not remove
/// without checking the migration plan.
enum OpenCVBridge {

    enum BridgeError: Error {
        case cgImageMissing
        case invalidOutputSize
        case warpFailed(String)
        case resizeFailed(String)
        case pyrDownFailed(String)
    }

    /// Warps **`source`** from axis-aligned image corners (TL, TR, BR, BL) into the mercator output rectangle described by **`destinationPoints`** (same corner order as **`OverlayMapBake`** / geographic **`corners`** indices).
    static func warpSourceToMercatorPNG(
        source: UIImage,
        destinationPoints: [CGPoint],
        outputWidth: Int,
        outputHeight: Int
    ) throws -> Data {
        guard outputWidth >= 2, outputHeight >= 2 else { throw BridgeError.invalidOutputSize }
        guard destinationPoints.count == 4 else {
            throw BridgeError.warpFailed("Expected 4 destination points")
        }
        guard let cg = OverlayMapBake.normalizedCGImage(from: source) else {
            throw BridgeError.cgImageMissing
        }
        return try destinationPoints.withUnsafeBufferPointer { buf -> Data in
            guard let base = buf.baseAddress else {
                throw BridgeError.warpFailed("destination buffer")
            }
            do {
                return try STMOpenCVBridge.perspectiveWarpPNG(
                    with: cg,
                    destinationPoints: base,
                    outputWidth: Int32(outputWidth),
                    outputHeight: Int32(outputHeight)
                )
            } catch {
                throw BridgeError.warpFailed(error.localizedDescription)
            }
        }
    }

    /// Decodes a PNG (RGBA preferred), resizes with OpenCV linear interpolation, re-encodes PNG.
    static func resizePNG(data: Data, width: Int, height: Int) throws -> Data {
        guard width >= 1, height >= 1 else { throw BridgeError.invalidOutputSize }
        do {
            return try STMOpenCVBridge.resizePNGData(data, width: Int32(width), height: Int32(height))
        } catch {
            throw BridgeError.resizeFailed(error.localizedDescription)
        }
    }

    /// One **`cv::pyrDown`** step (half resolution, 5×5 Gaussian). Requires **`cgImage`** at least **2×2** pixels.
    static func pyrDownCGImage(_ cgImage: CGImage) throws -> CGImage {
        do {
            return try STMOpenCVBridge.pyrDown(cgImage)
        } catch {
            throw BridgeError.pyrDownFailed(error.localizedDescription)
        }
    }
}
