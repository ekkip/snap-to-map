import CoreGraphics
import CoreLocation
import Foundation
import MapKit
import UIKit

/// Renders offline **`MKTileOverlay`** cells: chunked Metal inverse warp per tile, ImageIO HEIF output.
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
        let thumbnailCacheScope: String
        /// When set (pyramid builds), reuses one chunked source upload for all tiles at a revision.
        let metalSourceSession: OverlayMetalTilePipeline.ChunkedSourceSession?
        /// MapKit-requested zoom (for debug logging).
        let requestedZ: Int?
        /// Clamped source zoom used for generation (for debug logging).
        let sourceZ: Int?

        init(
            sourceRaster: Data,
            corners: [CLLocationCoordinate2D],
            mercatorPixelWidth: Int,
            mercatorPixelHeight: Int,
            tileRect: MKMapRect,
            bbox: MKMapRect,
            clipped: MKMapRect,
            tileSize: CGSize,
            contentScale: CGFloat,
            thumbnailCacheScope: String,
            metalSourceSession: OverlayMetalTilePipeline.ChunkedSourceSession? = nil,
            requestedZ: Int? = nil,
            sourceZ: Int? = nil
        ) {
            self.sourceRaster = sourceRaster
            self.corners = corners
            self.mercatorPixelWidth = mercatorPixelWidth
            self.mercatorPixelHeight = mercatorPixelHeight
            self.tileRect = tileRect
            self.bbox = bbox
            self.clipped = clipped
            self.tileSize = tileSize
            self.contentScale = contentScale
            self.thumbnailCacheScope = thumbnailCacheScope
            self.metalSourceSession = metalSourceSession
            self.requestedZ = requestedZ
            self.sourceZ = sourceZ
        }
    }

    static func mercatorTileHEIFData(from request: SourceTileRequest) -> Data? {
        guard request.corners.count == 4,
              request.mercatorPixelWidth >= 1,
              request.mercatorPixelHeight >= 1 else { return nil }
        guard let layout = OverlayMapBake.mercatorTileLayout(
            mercatorWidth: request.mercatorPixelWidth,
            mercatorHeight: request.mercatorPixelHeight,
            tileRect: request.tileRect,
            bbox: request.bbox,
            clipped: request.clipped,
            tileSize: request.tileSize,
            contentScale: request.contentScale
        ) else { return nil }

        let session: OverlayMetalTilePipeline.ChunkedSourceSession
        if let existing = request.metalSourceSession {
            session = existing
        } else if let created = try? OverlayMetalTilePipeline.sourceSession(
            sourceRaster: request.sourceRaster,
            corners: request.corners,
            mercatorPixelWidth: request.mercatorPixelWidth,
            mercatorPixelHeight: request.mercatorPixelHeight,
            cacheScope: request.thumbnailCacheScope
        ) {
            session = created
        } else {
            return nil
        }

        return OverlayMetalTilePipeline.mercatorTileHEIFData(
            session: session,
            layout: layout,
            requestedZ: request.requestedZ,
            sourceZ: request.sourceZ,
            knownOpaque: layout.tileFullyCoversOutput
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
}
