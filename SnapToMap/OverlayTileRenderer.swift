import CoreGraphics
import CoreLocation
import Foundation
import ImageIO
import MapKit
import UIKit

/// Renders offline **`MKTileOverlay`** cells: ImageIO source LOD, Core Image mercator warp, ImageIO HEIF output.
enum OverlayTileRenderer {

    struct SourceTileRequest {
        let sourceRaster: Data
        let corners: [CLLocationCoordinate2D]
        let mercatorPixelWidth: Int
        let mercatorPixelHeight: Int
        let tileRect: MKMapRect
        let bbox: MKMapRect
        let clipped: MKMapRect
        let tileSize: CGSize
        let contentScale: CGFloat
        let maxThumbnailDecodeSideOverride: Int?
        let thumbnailCacheScope: String
    }

    /// Longest-edge ImageIO thumbnail target for a zoom level given source density in map space.
    static func thumbnailDecodeSide(
        sourcePixelsPerMapPoint: CGFloat,
        z: Int,
        maxThumbnailDecodeSide: Int = 4608
    ) -> Int {
        guard z >= 0, z < 31 else { return maxThumbnailDecodeSide }
        let tileMapSpan = MKMapRect.world.size.width / CGFloat(1 << z)
        let sourcePixelsPerTile = sourcePixelsPerMapPoint * tileMapSpan
        let target = Int(min(CGFloat(maxThumbnailDecodeSide), max(1, sourcePixelsPerTile * 1.18)).rounded(.up))
        return max(1, target)
    }

    static func mercatorTileHEIFData(from request: SourceTileRequest) -> Data? {
        OverlayMapBake.mercatorTileHEIFDataFromSourceRaster(
            sourceRaster: request.sourceRaster,
            corners: request.corners,
            mercatorPixelWidth: request.mercatorPixelWidth,
            mercatorPixelHeight: request.mercatorPixelHeight,
            tileRect: request.tileRect,
            bbox: request.bbox,
            clipped: request.clipped,
            tileSize: request.tileSize,
            contentScale: request.contentScale,
            maxThumbnailDecodeSideOverride: request.maxThumbnailDecodeSideOverride,
            thumbnailCacheScope: request.thumbnailCacheScope
        )
    }

    static func mercatorTileHEIFDataFromBakedFallback(
        bakedFallbackCG: CGImage?,
        tileRect: MKMapRect,
        bbox: MKMapRect,
        clipped: MKMapRect,
        tileSize: CGSize,
        scale: CGFloat
    ) -> Data? {
        guard let bakedFallbackCG else { return nil }
        return OverlayTileBuildProfiling.measure(.warp) {
            BakedImageMapTileOverlay.mercatorTileHEIFDataForOfflinePyramid(
                sourceCGImage: bakedFallbackCG,
                tileRect: tileRect,
                bbox: bbox,
                clipped: clipped,
                tileSize: tileSize,
                contentScale: scale
            )
        }
    }

    /// Composites four child tiles from disk (incremental refinement fallback). Returns **`nil`** when any quadrant is missing.
    static func mercatorTileHEIFDataFromChildComposite(
        pyramidRoot: URL,
        parentPath: MKTileOverlayPath,
        scale: CGFloat,
        tileSize: CGSize
    ) -> Data? {
        OverlayTileBuildProfiling.measure(.composite) {
            compositeFromChildTilesOnDisk(
                pyramidRoot: pyramidRoot,
                parentPath: parentPath,
                scale: scale,
                tileSize: tileSize
            )
        }
    }

    /// Whether all four child tiles exist on disk at **`parentPath.z + 1`**.
    static func allChildTilesExistOnDisk(
        pyramidRoot: URL,
        parentPath: MKTileOverlayPath,
        scale: CGFloat
    ) -> Bool {
        let childZ = parentPath.z + 1
        guard childZ >= 0, childZ < 31 else { return false }
        let childBaseX = parentPath.x * 2
        let childBaseY = parentPath.y * 2
        for dx in 0...1 {
            for dy in 0...1 {
                let childPath = MKTileOverlayPath(
                    x: childBaseX + dx,
                    y: childBaseY + dy,
                    z: childZ,
                    contentScaleFactor: scale
                )
                let urls = OverlayLibrary.tileCandidateFileURLs(pyramidRoot: pyramidRoot, path: childPath)
                guard urls.contains(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
                    return false
                }
            }
        }
        return true
    }

    private static func compositeFromChildTilesOnDisk(
        pyramidRoot: URL,
        parentPath: MKTileOverlayPath,
        scale: CGFloat,
        tileSize: CGSize
    ) -> Data? {
        let childZ = parentPath.z + 1
        guard childZ >= 0, childZ < 31 else { return nil }
        let childBaseX = parentPath.x * 2
        let childBaseY = parentPath.y * 2
        let outW = Int(max(1, (tileSize.width * scale).rounded()))
        let outH = Int(max(1, (tileSize.height * scale).rounded()))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil,
                  width: outW,
                  height: outH,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }
        ctx.interpolationQuality = .high
        ctx.clear(CGRect(x: 0, y: 0, width: outW, height: outH))

        var drewAny = false
        let halfW = CGFloat(outW) / 2
        let halfH = CGFloat(outH) / 2
        for dx in 0...1 {
            for dy in 0...1 {
                let childPath = MKTileOverlayPath(
                    x: childBaseX + dx,
                    y: childBaseY + dy,
                    z: childZ,
                    contentScaleFactor: scale
                )
                var childCG: CGImage?
                let decodeStart = CFAbsoluteTimeGetCurrent()
                for childURL in OverlayLibrary.tileCandidateFileURLs(pyramidRoot: pyramidRoot, path: childPath) {
                    if let data = try? Data(contentsOf: childURL),
                       let src = CGImageSourceCreateWithData(data as CFData, nil),
                       let decoded = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                        childCG = decoded
                        break
                    }
                }
                OverlayTileBuildProfiling.record(.decode, seconds: CFAbsoluteTimeGetCurrent() - decodeStart)
                guard let childCG else { continue }
                let destX = CGFloat(dx) * halfW
                let destY = dy == 0 ? halfH : 0
                ctx.draw(childCG, in: CGRect(x: destX, y: destY, width: halfW, height: halfH))
                drewAny = true
            }
        }
        guard drewAny, let out = ctx.makeImage() else { return nil }
        return OverlayTileHEIFEncoding.encodeTileImageData(out)
    }
}
