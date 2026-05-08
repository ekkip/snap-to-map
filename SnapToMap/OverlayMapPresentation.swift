import CoreGraphics
import MapKit
import UIKit

// MARK: - Protocol

/// Map overlay types produced by **`OverlayMapPresentation`** for unified hit-testing, opacity, and removal.
protocol SnapRasterMapOverlay: MKOverlay {
    var overlayID: UUID { get }
    /// When **`true`**, browse-mode opacity uses **`committed`** until drag ends (see **`RasterMapOpacityBag`**).
    var presentationUsesHeavyOpacityPath: Bool { get }
    var opacityBag: RasterMapOpacityBag? { get }
}

extension ImageRasterMapOverlay: SnapRasterMapOverlay {
    var presentationUsesHeavyOpacityPath: Bool { largeImage }
}

// MARK: - Tile overlay (≥ threshold)

/// Serves **`MKTileOverlayPath`** tiles by cropping the baked mercator **`UIImage`**, avoiding one giant `draw` / full-bitmap crop for each visible map rect.
final class BakedImageMapTileOverlay: MKTileOverlay, SnapRasterMapOverlay {
    let overlayID: UUID
    let image: UIImage
    private let imageBoundingMapRect: MKMapRect

    weak var opacityBag: RasterMapOpacityBag?

    var presentationUsesHeavyOpacityPath: Bool { true }

    init(overlayID: UUID, image: UIImage, mapBoundingRect: MKMapRect, opacityBag: RasterMapOpacityBag) {
        self.overlayID = overlayID
        self.image = image
        self.imageBoundingMapRect = mapBoundingRect
        self.opacityBag = opacityBag
        super.init(urlTemplate: "snap-to-map-baked://local")
        canReplaceMapContent = false
        tileSize = CGSize(width: 256, height: 256)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var boundingMapRect: MKMapRect { imageBoundingMapRect }

    override var coordinate: CLLocationCoordinate2D {
        MKMapPoint(x: imageBoundingMapRect.midX, y: imageBoundingMapRect.midY).coordinate
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, (any Error)?) -> Void) {
        let tileRect = Self.mapRect(for: path, geometryFlipped: isGeometryFlipped)
        let bbox = imageBoundingMapRect
        let clipped = bbox.intersection(tileRect)
        if clipped.isNull || clipped.isEmpty || clipped.size.width <= 0 || clipped.size.height <= 0 {
            result(Self.transparentTilePNG(points: tileSize, scale: path.contentScaleFactor), nil)
            return
        }
        guard let data = Self.pngTileData(
            image: image,
            tileRect: tileRect,
            bbox: bbox,
            clipped: clipped,
            tileSize: tileSize,
            contentScale: path.contentScaleFactor
        ) else {
            result(Self.transparentTilePNG(points: tileSize, scale: path.contentScaleFactor), nil)
            return
        }
        result(data, nil)
    }

    /// Mercator **`MKMapRect`** covered by **`path`** (same tiling as **`MKTileOverlay`** / `MKMapRect.world`).
    private static func mapRect(for path: MKTileOverlayPath, geometryFlipped: Bool) -> MKMapRect {
        let world = MKMapRect.world
        let n = pow(2.0, Double(path.z))
        let tileW = world.size.width / n
        let tileH = world.size.height / n
        let ox = world.origin.x + Double(path.x) * tileW
        var oy = world.origin.y + Double(path.y) * tileH
        if geometryFlipped {
            oy = world.origin.y + world.size.height - Double(path.y + 1) * tileH
        }
        return MKMapRect(origin: MKMapPoint(x: ox, y: oy), size: MKMapSize(width: tileW, height: tileH))
    }

    private static func transparentTilePNG(points: CGSize, scale: CGFloat) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: points, format: format)
        let img = renderer.image { _ in }
        return img.pngData() ?? Data()
    }

    private static func pngTileData(
        image: UIImage,
        tileRect: MKMapRect,
        bbox: MKMapRect,
        clipped: MKMapRect,
        tileSize: CGSize,
        contentScale: CGFloat
    ) -> Data? {
        guard let cgImage = normalizedCGImage(from: image) else { return nil }
        let iw = CGFloat(cgImage.width)
        let ih = CGFloat(cgImage.height)
        guard iw > 0, ih > 0 else { return nil }

        let u0 = CGFloat((clipped.origin.x - bbox.origin.x) / bbox.size.width)
        let u1 = CGFloat((clipped.maxX - bbox.origin.x) / bbox.size.width)
        let v0 = CGFloat((clipped.origin.y - bbox.origin.y) / bbox.size.height)
        let v1 = CGFloat((clipped.maxY - bbox.origin.y) / bbox.size.height)

        let srcRect = CGRect(
            x: u0 * iw,
            y: v0 * ih,
            width: max(u1 - u0, 0) * iw,
            height: max(v1 - v0, 0) * ih
        ).integral
        guard srcRect.width >= 1, srcRect.height >= 1,
              let cropped = cgImage.cropping(to: srcRect) else {
            return nil
        }

        let tw = max(tileRect.width, 1)
        let th = max(tileRect.height, 1)
        let ow = tileSize.width
        let oh = tileSize.height
        let dx = CGFloat((clipped.origin.x - tileRect.origin.x) / tw) * ow
        let dy = CGFloat((clipped.origin.y - tileRect.origin.y) / th) * oh
        let dw = CGFloat(clipped.size.width / tw) * ow
        let dh = CGFloat(clipped.size.height / th) * oh
        guard dw >= 0.5, dh >= 0.5 else { return nil }

        let format = UIGraphicsImageRendererFormat()
        format.scale = contentScale
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: ow, height: oh), format: format)
        let out = renderer.image { ctx in
            let c = ctx.cgContext
            c.interpolationQuality = .high
            c.translateBy(x: dx, y: dy + dh)
            c.scaleBy(x: 1, y: -1)
            c.draw(cropped, in: CGRect(x: 0, y: 0, width: dw, height: dh))
        }
        return out.pngData()
    }

    private static func normalizedCGImage(from image: UIImage) -> CGImage? {
        if image.imageOrientation == .up, let cg = image.cgImage { return cg }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        let drawn = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: image.size)) }
        return drawn.cgImage
    }
}

// MARK: - Façade

/// Chooses **`ImageRasterMapOverlay`** (fast opacity drags) vs **`BakedImageMapTileOverlay`** when the
/// overlay’s **source** exceeds **`OverlayLibrary.largeRasterOverlayPixelThresholdExclusive`** (>100 MP), via
/// **`OverlayItem.usesTiledMapPresentation`** (frozen at item creation).
///
/// **Note:** Small sources still use **`ImageRasterMapOverlay`** with **`MKOverlayRenderer`**; MapKit calls
/// **`draw(mapRect:zoomScale:in:)`** for each visible region while panning — that is **not**
/// **`MKTileOverlay.loadTile`** (log `loadTile` only on **`BakedImageMapTileOverlay`** to tell them apart).
enum OverlayMapPresentation {
    case raster(ImageRasterMapOverlay)
    case tiled(BakedImageMapTileOverlay)

    static func make(
        overlayID: UUID,
        mapDisplayImage: UIImage,
        usesTiledMapPresentation: Bool,
        mapBoundingRect: MKMapRect,
        opacityBag: RasterMapOpacityBag
    ) -> OverlayMapPresentation {
        if usesTiledMapPresentation {
            return .tiled(
                BakedImageMapTileOverlay(
                    overlayID: overlayID,
                    image: mapDisplayImage,
                    mapBoundingRect: mapBoundingRect,
                    opacityBag: opacityBag
                )
            )
        }
        return .raster(
            ImageRasterMapOverlay(
                overlayID: overlayID,
                image: mapDisplayImage,
                mapBoundingRect: mapBoundingRect,
                largeImage: false,
                opacityBag: opacityBag
            )
        )
    }

    var mkOverlay: MKOverlay {
        switch self {
        case .raster(let o): return o
        case .tiled(let o): return o
        }
    }

    var snapRaster: SnapRasterMapOverlay { mkOverlay as! SnapRasterMapOverlay }

    var overlayID: UUID { snapRaster.overlayID }
}
