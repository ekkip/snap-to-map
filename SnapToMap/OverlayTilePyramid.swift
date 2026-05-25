import CoreGraphics
import CoreLocation
import CoreData
import Foundation
import ImageIO
import MapKit
import simd
import UIKit

extension Notification.Name {
    static let overlayTilePyramidIterationDidChange = Notification.Name("overlayTilePyramidIterationDidChange")
}

/// Generates MapKit **`MKTileOverlayPath`** HEIF pyramids under **`OverlayLibrary`** storage and updates **`StoredMapOverlay`** zoom metadata.
enum OverlayTilePyramidBuilder {
    private static let pyramidWorkerCount = 2
    /// One pyramid build at a time app‑wide (**`performBackgroundTask`** nesting previously ran refine + preview concurrently → jetsam).
    private static let pyramidBuildGate = DispatchSemaphore(value: 1)
    struct ZoomCeilings {
        /// Highest zoom where the overlay still fits in a single tile (early map display uses this level).
        let highestSingleTileZoom: Int
        /// First zoom that needs multiple tiles; **`fullMaximumZ + 1`** when never multi-tile.
        let firstMultiTileZoom: Int
        let previewMaximumZ: Int
        let fullMaximumZ: Int
    }

    static let debugIterationOverlayIDKey = "overlayID"
    static let debugIterationZoomLevelKey = "zoomLevel"
    static let debugIterationMaximumZoomKey = "maximumZoom"
    static let debugIterationLevelTileIndexKey = "levelTileIndex"
    static let debugIterationLevelTileTotalKey = "levelTileTotal"
    static let debugIterationElapsedSecondsKey = "elapsedSeconds"
    static let debugIterationFinishedKey = "finished"
    /// Clears UI progress labels before a new build writes stale z from the prior run.
    static let debugIterationResetKey = "reset"

    private static func notifyPyramidAvailability(overlayID: UUID) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .overlayTilePyramidRefinementDidComplete,
                object: nil,
                userInfo: ["overlayID": overlayID.uuidString]
            )
        }
    }

    private static func applyPyramidZoomMetadata(
        to row: StoredMapOverlay,
        minimumZ: Int,
        advertisedMaximumZoom: Int,
        fullMaximumZoom: Int,
        previewMaximumZoom: Int
    ) {
        let persistedMinimumZoom = row.tileMinimumZoom >= 0 ? Int(row.tileMinimumZoom) : minimumZ
        row.tileMinimumZoom = Int32(min(persistedMinimumZoom, minimumZ))
        row.tileMaximumZoom = Int32(advertisedMaximumZoom)
        row.tileMaximumZoomFull = Int32(fullMaximumZoom)
        row.tileMaximumZoomPreview = Int32(previewMaximumZoom)
        row.tileRefinementInProgress = advertisedMaximumZoom < fullMaximumZoom
    }

    private static func postIterationNotification(_ userInfo: [String: Any]) {
        let post = {
            NotificationCenter.default.post(
                name: .overlayTilePyramidIterationDidChange,
                object: nil,
                userInfo: userInfo
            )
        }
        if Thread.isMainThread {
            post()
        } else {
            DispatchQueue.main.async(execute: post)
        }
    }

    private static let agentDebugLogPath = "/Users/ekki/Library/CloudStorage/Dropbox/Programmator/GITHUB/snap-to-map/.cursor/debug-2c9d13.log"
    private static let agentDebugSessionId = "2c9d13"

    private static func agentDebugLog(
        runId: String,
        hypothesisId: String,
        location: String,
        message: String,
        data: [String: Any]
    ) {
        let now = Date().timeIntervalSince1970
        let ts = Int64((now * 1000.0).rounded())
        let eventID = "log_\(ts)_\(UInt64.random(in: 0...UInt64.max))"
        var payload: [String: Any] = [
            "sessionId": agentDebugSessionId,
            "id": eventID,
            "runId": runId,
            "hypothesisId": hypothesisId,
            "location": location,
            "message": message,
            "data": data,
            "timestamp": ts,
        ]
        if payload["data"] == nil {
            payload["data"] = [:]
        }
        guard let encoded = try? JSONSerialization.data(withJSONObject: payload, options: []),
              var line = String(data: encoded, encoding: .utf8) else { return }
        line.append("\n")
        let logURL = URL(fileURLWithPath: agentDebugLogPath, isDirectory: false)
        let bytes = Data(line.utf8)
        if FileManager.default.fileExists(atPath: logURL.path) {
            if let handle = try? FileHandle(forWritingTo: logURL) {
                defer { try? handle.close() }
                do {
                    try handle.seekToEnd()
                    try handle.write(contentsOf: bytes)
                } catch {
                    return
                }
            }
        } else {
            try? bytes.write(to: logURL, options: .atomic)
        }
    }

    /// Extra minZ cells written around the bbox intersection so first mount at overview zoom avoids MapKit neighbor misses.
    private static let minZOverviewNeighborhoodPadTiles = 1

    /// Builds **only** the minZ overview tile, persists progressive pyramid metadata, and returns quickly.
    static func buildMinZOverviewAndPersistRow(
        overlayID: UUID,
        revision: Int64,
        sourceRaster: Data,
        corners: [CLLocationCoordinate2D],
        bakedMercatorDisplay: UIImage,
        geometryFlipped: Bool,
        tileContentScale: CGFloat,
        row: StoredMapOverlay,
        context: NSManagedObjectContext
    ) throws {
        guard corners.count == 4 else { return }
        if OverlayLibrary.isPyramidBuildSuppressed(overlayID) {
            print("[TileDiag] build.minZ.skip id=\(overlayID.uuidString.prefix(8))… rev=\(revision) suppressedDuringEdit")
            return
        }
        let overlayTag = String(overlayID.uuidString.prefix(8))
        let thumbnailCacheScope = "\(overlayID.uuidString)-\(revision)"
        OverlayMapBake.beginThumbnailCacheScope(thumbnailCacheScope)
        defer {
            OverlayMapBake.endThumbnailCacheScope()
            OverlayMetalTilePipeline.clearSessionCache()
        }
        pyramidBuildGate.wait()
        defer { pyramidBuildGate.signal() }

        OverlayLibrary.noteActivePyramidBuildRevision(overlayID, revision: revision)
        let bbox = OverlayMapBake.mapBoundingMapRect(for: corners)
        let root = OverlayLibrary.tilePyramidRevisionDirectoryURL(id: overlayID, revision: revision)
        let fm = FileManager.default
        if fm.fileExists(atPath: root.path) {
            try? fm.removeItem(at: root)
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let intrinsic = intrinsicPixelSize(from: sourceRaster) ?? (
            width: max(1, Int((bakedMercatorDisplay.size.width * bakedMercatorDisplay.scale).rounded())),
            height: max(1, Int((bakedMercatorDisplay.size.height * bakedMercatorDisplay.scale).rounded()))
        )
        let bakedFallbackCG = OverlayMapBake.normalizedCGImage(from: bakedMercatorDisplay)
        let normalizedContentScale = OverlayLibrary.normalizedTileContentScale(tileContentScale)
        let ceilings = computeZoomCeilings(
            sourceIntrinsicSize: intrinsic,
            mercatorSize: (
                width: max(1, bakedMercatorDisplay.cgImage?.width ?? intrinsic.width),
                height: max(1, bakedMercatorDisplay.cgImage?.height ?? intrinsic.height)
            ),
            mapBoundingRect: bbox,
            tileContentScale: normalizedContentScale,
            geometryFlipped: geometryFlipped
        )
        let minZ = ceilings.highestSingleTileZoom
        let maxZ = ceilings.fullMaximumZ
        guard OverlayLibrary.isCurrentPyramidBuildRevision(overlayID, revision: revision) else { return }

        let yIndexMode = geometryFlipped ? "legacyFlipped" : "xyzTopDown"
        try OverlayLibrary.writeTilePyramidMetadata(
            to: root,
            yIndexMode: yIndexMode,
            tileContentScale: normalizedContentScale,
            minZ: minZ,
            maxZ: maxZ,
            sourceWidth: intrinsic.width,
            sourceHeight: intrinsic.height
        )

        print("[TileDiag] build.minZ.begin id=\(overlayTag) rev=\(revision) minZ=\(minZ) maxZ=\(maxZ) intrinsic=\(intrinsic.width)x\(intrinsic.height)")
        OverlaySaveTransitionLog.stage("minZ.build.begin", overlayID: overlayID, extra: "minZ=\(minZ) maxZ=\(maxZ)")

        let tileSize = OverlayLibrary.logicalTileSize
        guard let xy = intersectingTileIndexBounds(
            mapBoundingRect: bbox,
            z: minZ,
            geometryFlipped: geometryFlipped,
            padTiles: minZOverviewNeighborhoodPadTiles
        ) else {
            print("[TileDiag] build.minZ.abort id=\(overlayTag) no intersecting cell at minZ=\(minZ)")
            return
        }

        for y in xy.y0...xy.y1 {
            for x in xy.x0...xy.x1 {
                let dir = OverlayLibrary.tileDataFileURL(
                    pyramidRoot: root,
                    path: MKTileOverlayPath(x: x, y: y, z: minZ, contentScaleFactor: normalizedContentScale)
                ).deletingLastPathComponent()
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
        }

        var written = 0
        var buildAborted = false
        outer: for y in xy.y0...xy.y1 {
            for x in xy.x0...xy.x1 {
                guard OverlayLibrary.isCurrentPyramidBuildRevision(overlayID, revision: revision) else {
                    buildAborted = true
                    break outer
                }
                try autoreleasepool {
                    let path = MKTileOverlayPath(x: x, y: y, z: minZ, contentScaleFactor: normalizedContentScale)
                    let tileRect = BakedImageMapTileOverlay.mercatorMapRectForOfflinePyramid(path: path, geometryFlipped: geometryFlipped)
                    let clipped = bbox.intersection(tileRect)
                    let url = OverlayLibrary.tileDataFileURL(pyramidRoot: root, path: path)

                    if clipped.isNull || clipped.isEmpty {
                        guard let data = OverlayLibrary.transparentTileHEIFData(
                            logicalTileSize: tileSize,
                            contentScale: normalizedContentScale
                        ) else { return }
                        try OverlayLibrary.atomicWriteTileData(data, to: url)
                        written += 1
                        print("[TileDiag] build.minZ.transparentNeighbor id=\(overlayTag) z=\(minZ) x=\(x) y=\(y)")
                        return
                    }

                    // minZ overview: baked mercator is sufficient and avoids a full intrinsic Metal session.
                    if let data = OverlayTileRenderer.mercatorTileHEIFDataFromBakedFallback(
                        bakedFallbackCG: bakedFallbackCG,
                        tileRect: tileRect,
                        bbox: bbox,
                        clipped: clipped,
                        tileSize: tileSize,
                        scale: normalizedContentScale
                    ) {
                        try OverlayLibrary.atomicWriteTileData(data, to: url)
                        written += 1
                        print("[TileDiag] build.minZ.bakedFallback id=\(overlayTag) z=\(minZ) x=\(x) y=\(y)")
                        return
                    }

                    print("[TileDiag] build.minZ.metalFallback id=\(overlayTag) z=\(minZ) x=\(x) y=\(y)")
                    let metalSourceSession = try OverlayMetalTilePipeline.sourceSession(
                        sourceRaster: sourceRaster,
                        corners: corners,
                        mercatorPixelWidth: intrinsic.width,
                        mercatorPixelHeight: intrinsic.height,
                        cacheScope: thumbnailCacheScope
                    )
                    let sourceRequest = OverlayTileRenderer.SourceTileRequest(
                        sourceRaster: sourceRaster,
                        corners: corners,
                        mercatorPixelWidth: intrinsic.width,
                        mercatorPixelHeight: intrinsic.height,
                        tileRect: tileRect,
                        bbox: bbox,
                        clipped: clipped,
                        tileSize: tileSize,
                        contentScale: normalizedContentScale,
                        thumbnailCacheScope: thumbnailCacheScope,
                        metalSourceSession: metalSourceSession,
                        requestedZ: minZ,
                        sourceZ: minZ
                    )
                    guard let data = OverlayTileRenderer.mercatorTileHEIFData(from: sourceRequest) else { return }
                    try OverlayLibrary.atomicWriteTileData(data, to: url)
                    written += 1
                    OverlayMetalTilePipeline.clearSessionCache()
                }
            }
        }
        if buildAborted { return }

        guard OverlayLibrary.isCurrentPyramidBuildRevision(overlayID, revision: revision) else { return }
        applyPyramidZoomMetadata(
            to: row,
            minimumZ: minZ,
            advertisedMaximumZoom: maxZ,
            fullMaximumZoom: maxZ,
            previewMaximumZoom: minZ
        )
        row.tileRefinementInProgress = maxZ > minZ || written == 0
        try context.save()

        print("[TileDiag] build.minZ.end id=\(overlayTag) rev=\(revision) minZ=\(minZ) maxZ=\(maxZ) written=\(written)")
        OverlaySaveTransitionLog.stage("minZ.build.end", overlayID: overlayID, extra: "written=\(written)")
        // Save transition UI listens to `.overlayTilePyramidMinZReady` only — skip refinement notification to avoid double `loadOverlays`.
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .overlayTilePyramidMinZReady,
                object: nil,
                userInfo: [
                    "overlayID": overlayID.uuidString,
                    "minZ": minZ,
                    "maxZ": maxZ,
                ]
            )
        }
    }

    /// Builds tiles for **`revision`** (caller already bumped **`StoredMapOverlay.tilePyramidRevision`**). Writes **`tileMinimumZoom`** / **`tileMaximumZoom`** when successful.
    static func buildAndPersistRow(
        overlayID: UUID,
        revision: Int64,
        sourceRaster: Data,
        corners: [CLLocationCoordinate2D],
        bakedMercatorDisplay: UIImage,
        geometryFlipped: Bool,
        tileContentScale: CGFloat,
        buildMinimumZoom: Int? = nil,
        buildMaximumZoom: Int? = nil,
        advertisedAvailableMaximumZoom: Int? = nil,
        targetFullMaximumZoom: Int? = nil,
        previewMaximumZoom: Int? = nil,
        row: StoredMapOverlay,
        context: NSManagedObjectContext
    ) throws {
        guard corners.count == 4 else { return }
        if OverlayLibrary.isPyramidBuildSuppressed(overlayID) {
            print("[TileDiag] build.skip id=\(overlayID.uuidString.prefix(8))… rev=\(revision) suppressedDuringEdit")
            return
        }
        let overlayTag = String(overlayID.uuidString.prefix(8))
        let thumbnailCacheScope = "\(overlayID.uuidString)-\(revision)"
        OverlayMapBake.beginThumbnailCacheScope(thumbnailCacheScope)
        try OverlayTileBuildProfiling.withSession(label: "pyramid id=\(overlayTag) rev=\(revision)") {
            try buildAndPersistRowImpl(
                overlayID: overlayID,
                revision: revision,
                sourceRaster: sourceRaster,
                corners: corners,
                bakedMercatorDisplay: bakedMercatorDisplay,
                geometryFlipped: geometryFlipped,
                tileContentScale: tileContentScale,
                buildMinimumZoom: buildMinimumZoom,
                buildMaximumZoom: buildMaximumZoom,
                advertisedAvailableMaximumZoom: advertisedAvailableMaximumZoom,
                targetFullMaximumZoom: targetFullMaximumZoom,
                previewMaximumZoom: previewMaximumZoom,
                row: row,
                context: context,
                overlayTag: overlayTag,
                thumbnailCacheScope: thumbnailCacheScope
            )
        }
    }

    private static func buildAndPersistRowImpl(
        overlayID: UUID,
        revision: Int64,
        sourceRaster: Data,
        corners: [CLLocationCoordinate2D],
        bakedMercatorDisplay: UIImage,
        geometryFlipped: Bool,
        tileContentScale: CGFloat,
        buildMinimumZoom: Int?,
        buildMaximumZoom: Int?,
        advertisedAvailableMaximumZoom: Int?,
        targetFullMaximumZoom: Int?,
        previewMaximumZoom: Int?,
        row: StoredMapOverlay,
        context: NSManagedObjectContext,
        overlayTag: String,
        thumbnailCacheScope: String
    ) throws {
        pyramidBuildGate.wait()
        defer {
            pyramidBuildGate.signal()
            OverlayMapBake.endThumbnailCacheScope()
            OverlayMetalTilePipeline.clearSessionCache()
            postIterationNotification(
                [
                    debugIterationOverlayIDKey: overlayID.uuidString,
                    debugIterationFinishedKey: true,
                ]
            )
        }
        OverlayLibrary.noteActivePyramidBuildRevision(overlayID, revision: revision)
        SnapMemoryInstrumentation.checkpoint(
            "pyramid.build.begin id=\(overlayTag)… rev=\(revision) sourceBytes=\(sourceRaster.count)"
        )
        let bbox = OverlayMapBake.mapBoundingMapRect(for: corners)
        let root = OverlayLibrary.tilePyramidRevisionDirectoryURL(id: overlayID, revision: revision)
        print("[TileDiag] build.begin id=\(overlayTag) rev=\(revision) root=\(root.path)")
        print("[TileDiag] build.bbox id=\(overlayTag) origin=(\(bbox.origin.x),\(bbox.origin.y)) size=(\(bbox.size.width),\(bbox.size.height))")
        // #region agent log
        agentDebugLog(
            runId: "pre-fix",
            hypothesisId: "H2_bbox_collapse",
            location: "OverlayTilePyramid.swift:buildAndPersistRow.begin",
            message: "bbox and world coverage",
            data: [
                "overlayTag": overlayTag,
                "revision": revision,
                "bboxOriginX": bbox.origin.x,
                "bboxOriginY": bbox.origin.y,
                "bboxWidth": bbox.size.width,
                "bboxHeight": bbox.size.height,
                "worldWidth": MKMapRect.world.size.width,
                "worldHeight": MKMapRect.world.size.height,
                "geometryFlipped": geometryFlipped,
            ]
        )
        // #endregion

        let intrinsic = intrinsicPixelSize(from: sourceRaster) ?? (
            width: max(1, Int((bakedMercatorDisplay.size.width * bakedMercatorDisplay.scale).rounded())),
            height: max(1, Int((bakedMercatorDisplay.size.height * bakedMercatorDisplay.scale).rounded()))
        )

        let mercatorWidth = max(1, bakedMercatorDisplay.cgImage?.width ?? intrinsic.width)
        let mercatorHeight = max(1, bakedMercatorDisplay.cgImage?.height ?? intrinsic.height)
        let bakedFallbackCG = OverlayMapBake.normalizedCGImage(from: bakedMercatorDisplay)

        let normalizedContentScale = OverlayLibrary.normalizedTileContentScale(tileContentScale)
        let runtimeDeviceScale = OverlayLibrary.normalizedTileContentScale(UIScreen.main.scale)
        if normalizedContentScale != runtimeDeviceScale {
            print("[TileDiag] build.scaleMismatch id=\(overlayTag) tileContentScale=\(normalizedContentScale) UIScreen.main.scale=\(runtimeDeviceScale) — encoding uses tileContentScale from build request")
        }

        let ceilings = computeZoomCeilings(
            sourceIntrinsicSize: intrinsic,
            mercatorSize: (width: mercatorWidth, height: mercatorHeight),
            mapBoundingRect: bbox,
            tileContentScale: normalizedContentScale,
            geometryFlipped: geometryFlipped
        )
        let fullMaximumZ = ceilings.fullMaximumZ
        let minimumZ: Int = buildMinimumZoom ?? ceilings.highestSingleTileZoom
        let maximumZ: Int = buildMaximumZoom ?? fullMaximumZ
        guard maximumZ >= minimumZ else { return }
        guard OverlayLibrary.isCurrentPyramidBuildRevision(overlayID, revision: revision) else {
            print("[TileDiag] build.abort id=\(overlayTag) rev=\(revision) superseded")
            return
        }

        let fm = FileManager.default
        let preserveExistingTiles = minimumZ > ceilings.highestSingleTileZoom
        let yIndexMode = geometryFlipped ? "legacyFlipped" : "xyzTopDown"
        if preserveExistingTiles {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            let metaURL = root.appendingPathComponent("pyramid-meta.json", isDirectory: false)
            if !fm.fileExists(atPath: metaURL.path) {
                try OverlayLibrary.writeTilePyramidMetadata(
                    to: root,
                    yIndexMode: yIndexMode,
                    tileContentScale: normalizedContentScale
                )
            }
        } else {
            if fm.fileExists(atPath: root.path) {
                try? fm.removeItem(at: root)
            }
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            try OverlayLibrary.writeTilePyramidMetadata(
                to: root,
                yIndexMode: yIndexMode,
                tileContentScale: normalizedContentScale
            )
        }

        let sourcePixelCount = Int64(intrinsic.width) * Int64(intrinsic.height)
        let heavySource = sourcePixelCount > OverlayLibrary.largeRasterOverlayPixelThresholdExclusive
        let workerCount = heavySource ? 1 : pyramidWorkerCount

        SnapMemoryInstrumentation.checkpoint(
            "pyramid.config.ready pyramidTex=\(mercatorWidth)x\(mercatorHeight) fileIntrinsic=\(intrinsic.width)x\(intrinsic.height) maximumZ=\(maximumZ)"
        )
        // #region agent log
        agentDebugLog(
            runId: "pre-fix",
            hypothesisId: "H1_max_zoom_underestimated",
            location: "OverlayTilePyramid.swift:buildAndPersistRow.maxZoom",
            message: "max zoom inputs",
            data: [
                "overlayTag": overlayTag,
                "revision": revision,
                "sourceIntrinsicWidth": intrinsic.width,
                "sourceIntrinsicHeight": intrinsic.height,
                "mercatorWidth": mercatorWidth,
                "mercatorHeight": mercatorHeight,
                "mercatorNativeMaxZ": OverlayMapBake.nativeMaxZoomLevel(
                    intrinsicPixelWidth: mercatorWidth,
                    intrinsicPixelHeight: mercatorHeight,
                    mapBoundingRect: bbox,
                    tileSizePoints: OverlayLibrary.logicalTileSizePoints,
                    screenScale: normalizedContentScale
                ),
                "sourceNativeMaxZ": OverlayMapBake.nativeMaxZoomLevel(
                    intrinsicPixelWidth: intrinsic.width,
                    intrinsicPixelHeight: intrinsic.height,
                    mapBoundingRect: bbox,
                    tileSizePoints: OverlayLibrary.logicalTileSizePoints,
                    screenScale: normalizedContentScale
                ),
                "maximumZ": maximumZ,
                "tileContentScale": normalizedContentScale,
                "physicalTilePx": OverlayLibrary.physicalTileSizePixels(tileContentScale: normalizedContentScale),
            ]
        )
        // #endregion

        let tileSize = OverlayLibrary.logicalTileSize
        let scales: [CGFloat] = [normalizedContentScale]
        let physicalTilePx = OverlayLibrary.physicalTileSizePixels(tileContentScale: normalizedContentScale)
        var writtenByZ: [Int: Int] = [:]
        var intersectingCellByZ: [Int: Int] = [:]

        print("[TileDiag] build.zoomRange id=\(overlayTag) zMin=\(minimumZ) zMax=\(maximumZ) physicalTilePx=\(physicalTilePx) tileContentScale=\(normalizedContentScale) intrinsic=\(intrinsic.width)x\(intrinsic.height)")

        postIterationNotification(
            [
                debugIterationOverlayIDKey: overlayID.uuidString,
                debugIterationResetKey: true,
                debugIterationFinishedKey: false,
            ]
        )

        SnapMemoryInstrumentation.checkpoint(
            "pyramid.chunkedSource.begin id=\(overlayTag) intrinsic=\(intrinsic.width)x\(intrinsic.height)"
        )
        let metalSourceSession = try OverlayMetalTilePipeline.sourceSession(
            sourceRaster: sourceRaster,
            corners: corners,
            mercatorPixelWidth: intrinsic.width,
            mercatorPixelHeight: intrinsic.height,
            cacheScope: thumbnailCacheScope
        )
        defer { OverlayMetalTilePipeline.clearSessionCache() }
        SnapMemoryInstrumentation.checkpoint(
            "pyramid.chunkedSource.ready id=\(overlayTag) chunks=\(metalSourceSession.chunks.count) source=\(metalSourceSession.sourcePixelWidth)x\(metalSourceSession.sourcePixelHeight)"
        )

        for z in minimumZ...maximumZ {
            guard OverlayLibrary.isCurrentPyramidBuildRevision(overlayID, revision: revision) else {
                print("[TileDiag] build.abort id=\(overlayTag) rev=\(revision) superseded at z=\(z)")
                return
            }
            let levelStartedAt = Date()
            postIterationNotification(
                [
                    debugIterationOverlayIDKey: overlayID.uuidString,
                    debugIterationZoomLevelKey: z,
                    debugIterationMaximumZoomKey: maximumZ,
                    debugIterationElapsedSecondsKey: 0.0,
                    debugIterationFinishedKey: false,
                ]
            )
            var writtenAtZ = 0
            var attemptedAtZ = 0
            var tileNilAtZ = 0
            if let xy = intersectingTileIndexBounds(
                mapBoundingRect: bbox,
                z: z,
                geometryFlipped: geometryFlipped,
                padTiles: 0
            ) {
                let cells = (xy.x1 - xy.x0 + 1) * (xy.y1 - xy.y0 + 1)
                intersectingCellByZ[z] = cells
                var processedCells = 0
                // #region agent log
                agentDebugLog(
                    runId: "pre-fix",
                    hypothesisId: "H4_tile_bounds_too_small",
                    location: "OverlayTilePyramid.swift:buildAndPersistRow.bounds",
                    message: "computed intersecting tile bounds",
                    data: [
                        "z": z,
                        "x0": xy.x0,
                        "x1": xy.x1,
                        "y0": xy.y0,
                        "y1": xy.y1,
                        "cells": cells,
                        "padTiles": 0,
                    ]
                )
                // #endregion
                SnapMemoryInstrumentation.checkpoint(
                    "pyramid.loop.z=\(z)/\(maximumZ) intersectingCells=\(cells)"
                )
                // Pre-create z/x directories once per level to reduce per-tile filesystem overhead.
                var preparedXDirectories = Set<String>()
                for x in xy.x0...xy.x1 {
                    for scale in scales {
                        let samplePath = MKTileOverlayPath(x: x, y: 0, z: z, contentScaleFactor: scale)
                        let dir = OverlayLibrary.tileDataFileURL(pyramidRoot: root, path: samplePath).deletingLastPathComponent()
                        if preparedXDirectories.insert(dir.path).inserted {
                            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                        }
                    }
                }
                let cellCoords: [(x: Int, y: Int)] = (xy.x0...xy.x1).flatMap { x in (xy.y0...xy.y1).map { (x: x, y: $0) } }

                func processCell(x: Int, y: Int) throws -> (attempted: Int, written: Int, tileNil: Int) {
                    guard OverlayLibrary.isCurrentPyramidBuildRevision(overlayID, revision: revision) else {
                        return (0, 0, 0)
                    }
                    let path = MKTileOverlayPath(x: x, y: y, z: z, contentScaleFactor: 1)
                    let tileRect = BakedImageMapTileOverlay.mercatorMapRectForOfflinePyramid(path: path, geometryFlipped: geometryFlipped)
                    let clipped = bbox.intersection(tileRect)
                    guard !clipped.isNull, !clipped.isEmpty else { return (0, 0, 0) }
                    var attempted = 0
                    var written = 0
                    var tileNil = 0
                    for scale in scales {
                        attempted += 1
                        let scaledPath = MKTileOverlayPath(x: x, y: y, z: z, contentScaleFactor: scale)
                        let sourceRequest = OverlayTileRenderer.SourceTileRequest(
                            sourceRaster: sourceRaster,
                            corners: corners,
                            mercatorPixelWidth: intrinsic.width,
                            mercatorPixelHeight: intrinsic.height,
                            tileRect: tileRect,
                            bbox: bbox,
                            clipped: clipped,
                            tileSize: tileSize,
                            contentScale: scale,
                            thumbnailCacheScope: thumbnailCacheScope,
                            metalSourceSession: metalSourceSession,
                            requestedZ: z,
                            sourceZ: z
                        )
                        let data = autoreleasepool { () -> Data? in
                            if let fromSource = OverlayTileRenderer.mercatorTileHEIFData(from: sourceRequest) {
                                return fromSource
                            }
                            return OverlayTileRenderer.mercatorTileHEIFDataFromBakedFallback(
                                bakedFallbackCG: bakedFallbackCG,
                                tileRect: tileRect,
                                bbox: bbox,
                                clipped: clipped,
                                tileSize: tileSize,
                                scale: scale
                            )
                        }
                        guard let data else {
                            tileNil += 1
                            OverlayTileBuildProfiling.activeSession?.recordTileNil()
                            continue
                        }
                        OverlayTileBuildProfiling.activeSession?.recordTileProduced()
                        let url = OverlayLibrary.tileDataFileURL(pyramidRoot: root, path: scaledPath)
                        let ioStart = CFAbsoluteTimeGetCurrent()
                        try data.write(to: url, options: .atomic)
                        OverlayTileBuildProfiling.record(.diskIO, seconds: CFAbsoluteTimeGetCurrent() - ioStart)
                        TileDiagFileLog.append("[TileDiagFile] writing z=\(scaledPath.z) x=\(scaledPath.x) y=\(scaledPath.y) scale=\(scale) -> \(url.path)")
                        written += 1
                    }
                    return (attempted, written, tileNil)
                }

                if cellCoords.count > 1 {
                    let sem = DispatchSemaphore(value: workerCount)
                    let group = DispatchGroup()
                    let q = DispatchQueue(label: "snap-to-map.pyramid.top-level-workers", qos: .userInitiated, attributes: .concurrent)
                    let lock = NSLock()
                    var firstError: Error?

                    for c in cellCoords {
                        sem.wait()
                        group.enter()
                        q.async {
                            defer {
                                sem.signal()
                                group.leave()
                            }
                            lock.lock()
                            let shouldSkip = firstError != nil
                            lock.unlock()
                            if shouldSkip { return }
                            do {
                                let s = try processCell(x: c.x, y: c.y)
                                var currentProcessed = 0
                                lock.lock()
                                attemptedAtZ += s.attempted
                                writtenAtZ += s.written
                                tileNilAtZ += s.tileNil
                                processedCells += 1
                                currentProcessed = processedCells
                                let shouldPostProgress = processedCells == 1 || processedCells % 8 == 0 || processedCells == cells
                                lock.unlock()
                                if shouldPostProgress {
                                    postIterationNotification(
                                        [
                                            debugIterationOverlayIDKey: overlayID.uuidString,
                                            debugIterationZoomLevelKey: z,
                                            debugIterationMaximumZoomKey: maximumZ,
                                            debugIterationLevelTileIndexKey: currentProcessed,
                                            debugIterationLevelTileTotalKey: cells,
                                            debugIterationElapsedSecondsKey: Date().timeIntervalSince(levelStartedAt),
                                            debugIterationFinishedKey: false,
                                        ]
                                    )
                                }
                            } catch {
                                lock.lock()
                                if firstError == nil { firstError = error }
                                lock.unlock()
                            }
                        }
                    }
                    group.wait()
                    if let firstError { throw firstError }
                } else {
                    for c in cellCoords {
                        let s = try processCell(x: c.x, y: c.y)
                        attemptedAtZ += s.attempted
                        writtenAtZ += s.written
                        tileNilAtZ += s.tileNil
                        processedCells += 1
                        let shouldPostProgress = processedCells == 1 || processedCells % 8 == 0 || processedCells == cells
                        if shouldPostProgress {
                            postIterationNotification(
                                [
                                    debugIterationOverlayIDKey: overlayID.uuidString,
                                    debugIterationZoomLevelKey: z,
                                    debugIterationMaximumZoomKey: maximumZ,
                                    debugIterationLevelTileIndexKey: processedCells,
                                    debugIterationLevelTileTotalKey: cells,
                                    debugIterationElapsedSecondsKey: Date().timeIntervalSince(levelStartedAt),
                                    debugIterationFinishedKey: false,
                                ]
                            )
                        }
                    }
                }
            }
            writtenByZ[z] = writtenAtZ
            let expectedCellsLabel = intersectingCellByZ[z].map(String.init) ?? "0"
            let tileMapSpan = MKMapRect.world.size.width / Double(1 << z)
            let sourcePixelsPerMapPoint = min(
                Double(intrinsic.width) / max(1, bbox.size.width),
                Double(intrinsic.height) / max(1, bbox.size.height)
            )
            let sourcePixelsPerTile = sourcePixelsPerMapPoint * tileMapSpan
            let detailCoverage = physicalTilePx > 0 ? sourcePixelsPerTile / Double(physicalTilePx) : 0
            print("[TileDiag] build.level id=\(overlayTag) rev=\(revision) z=\(z) expectedCells=\(expectedCellsLabel) writtenTiles=\(writtenAtZ) sourcePxPerTile=\(Int(sourcePixelsPerTile.rounded())) physicalTilePx=\(physicalTilePx) detailCoverage=\(String(format: "%.2f", detailCoverage))")
            // #region agent log
            agentDebugLog(
                runId: "pre-fix",
                hypothesisId: "H3_tiles_dropped_during_render",
                location: "OverlayTilePyramid.swift:buildAndPersistRow.level",
                message: "level write stats",
                data: [
                    "z": z,
                    "expectedCells": intersectingCellByZ[z] ?? 0,
                    "attemptedTiles": attemptedAtZ,
                    "writtenTiles": writtenAtZ,
                    "tileNilCount": tileNilAtZ,
                ]
            )
            // #endregion

            if z == ceilings.highestSingleTileZoom,
               maximumZ > ceilings.highestSingleTileZoom {
                guard OverlayLibrary.isCurrentPyramidBuildRevision(overlayID, revision: revision) else {
                    print("[TileDiag] build.abort id=\(overlayTag) rev=\(revision) superseded after preview z=\(z)")
                    return
                }
                let resolvedPreviewZ = previewMaximumZoom ?? ceilings.previewMaximumZ
                let resolvedFullZ = targetFullMaximumZoom ?? fullMaximumZ
                applyPyramidZoomMetadata(
                    to: row,
                    minimumZ: minimumZ,
                    advertisedMaximumZoom: resolvedPreviewZ,
                    fullMaximumZoom: resolvedFullZ,
                    previewMaximumZoom: resolvedPreviewZ
                )
                try context.save()
                print("[TileDiag] build.interimPreview id=\(overlayTag) rev=\(revision) previewZ=\(resolvedPreviewZ) continuingToZ=\(maximumZ)")
                notifyPyramidAvailability(overlayID: overlayID)
            }
        }

        SnapMemoryInstrumentation.checkpoint(
            "pyramid.build.beforePersistZoomMeta id=\(overlayID.uuidString.prefix(8))… maxZ=\(maximumZ)"
        )
        guard OverlayLibrary.isCurrentPyramidBuildRevision(overlayID, revision: revision) else {
            print("[TileDiag] build.abort id=\(overlayTag) rev=\(revision) superseded before persist")
            return
        }
        let resolvedPreviewZ = previewMaximumZoom ?? ceilings.previewMaximumZ
        let resolvedFullZ = targetFullMaximumZoom ?? fullMaximumZ
        let resolvedAdvertisedZ = advertisedAvailableMaximumZoom ?? maximumZ
        applyPyramidZoomMetadata(
            to: row,
            minimumZ: minimumZ,
            advertisedMaximumZoom: resolvedAdvertisedZ,
            fullMaximumZoom: resolvedFullZ,
            previewMaximumZoom: resolvedPreviewZ
        )
        try context.save()
        notifyPyramidAvailability(overlayID: overlayID)
        let totalTiles = writtenByZ.values.reduce(0, +)
        let zSummary = writtenByZ.keys.sorted().map { z in
            "z\(z):\(writtenByZ[z] ?? 0)"
        }.joined(separator: ",")
        print("[TileDiag] build.end id=\(overlayTag) rev=\(revision) minZ=\(minimumZ) maxZ=\(maximumZ) totalTiles=\(totalTiles)")
        print("[TileDiag] build.levelSummary id=\(overlayTag) rev=\(revision) \(zSummary)")
        // #region agent log
        agentDebugLog(
            runId: "pre-fix",
            hypothesisId: "H5_summary",
            location: "OverlayTilePyramid.swift:buildAndPersistRow.end",
            message: "build summary",
            data: [
                "overlayTag": overlayTag,
                "revision": revision,
                "minimumZ": minimumZ,
                "maximumZ": maximumZ,
                "totalTiles": totalTiles,
                "levelSummary": zSummary,
            ]
        )
        // #endregion
    }

    static func computeZoomCeilings(
        sourceIntrinsicSize: (width: Int, height: Int),
        mercatorSize: (width: Int, height: Int),
        mapBoundingRect bbox: MKMapRect,
        tileContentScale: CGFloat,
        geometryFlipped: Bool = false
    ) -> ZoomCeilings {
        let scale = OverlayLibrary.normalizedTileContentScale(tileContentScale)
        let mercatorNativeMaxZ = OverlayMapBake.nativeMaxZoomLevel(
            intrinsicPixelWidth: mercatorSize.width,
            intrinsicPixelHeight: mercatorSize.height,
            mapBoundingRect: bbox,
            tileSizePoints: OverlayLibrary.logicalTileSizePoints,
            screenScale: scale
        )
        let sourceNativeMaxZ = OverlayMapBake.nativeMaxZoomLevel(
            intrinsicPixelWidth: sourceIntrinsicSize.width,
            intrinsicPixelHeight: sourceIntrinsicSize.height,
            mapBoundingRect: bbox,
            tileSizePoints: OverlayLibrary.logicalTileSizePoints,
            screenScale: scale
        )
        // Pyramid detail comes from per-tile **source** LOD; maxZ is first zoom that reaches/exceeds native resolution.
        let fullMaximumZ = OverlayMapBake.nativeOverresolveMaxZoomLevel(
            intrinsicPixelWidth: sourceIntrinsicSize.width,
            intrinsicPixelHeight: sourceIntrinsicSize.height,
            mapBoundingRect: bbox,
            tileSizePoints: OverlayLibrary.logicalTileSizePoints,
            screenScale: scale
        )
        let highestSingleTileZoom = highestSingleTileZoomLevel(
            mapBoundingRect: bbox,
            geometryFlipped: geometryFlipped,
            through: fullMaximumZ
        )
        let firstMultiTileZoom = min(fullMaximumZ + 1, highestSingleTileZoom + 1)
        // Preview: one tile at the finest zoom that still fits in a single cell.
        let previewMaximumZ = highestSingleTileZoom
        return ZoomCeilings(
            highestSingleTileZoom: highestSingleTileZoom,
            firstMultiTileZoom: firstMultiTileZoom,
            previewMaximumZ: previewMaximumZ,
            fullMaximumZ: fullMaximumZ
        )
    }

    /// Highest **`z`** (≤ **`through`**) where **`mapBoundingRect`** intersects exactly one tile.
    static func highestSingleTileZoomLevel(
        mapBoundingRect bbox: MKMapRect,
        geometryFlipped: Bool,
        through maximumZ: Int
    ) -> Int {
        guard maximumZ >= 0 else { return 0 }
        var highest = 0
        for z in 0...maximumZ {
            guard intersectingTileCellCount(mapBoundingRect: bbox, z: z, geometryFlipped: geometryFlipped) == 1 else {
                break
            }
            highest = z
        }
        return highest
    }

    /// Inclusive tile cell count intersecting **`mapBoundingRect`** at zoom **`z`**.
    static func intersectingTileCellCount(
        mapBoundingRect bbox: MKMapRect,
        z: Int,
        geometryFlipped: Bool
    ) -> Int {
        guard let xy = intersectingTileIndexBounds(
            mapBoundingRect: bbox,
            z: z,
            geometryFlipped: geometryFlipped,
            padTiles: 0
        ) else { return 0 }
        return (xy.x1 - xy.x0 + 1) * (xy.y1 - xy.y0 + 1)
    }

    private static func intrinsicPixelSize(from data: Data) -> (width: Int, height: Int)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? NSNumber,
              let h = props[kCGImagePropertyPixelHeight] as? NSNumber else {
            return nil
        }
        return (w.intValue, h.intValue)
    }

    /// Tile index ranges intersecting **`mapBoundingRect`** (inclusive), clamped to the **`z`** grid.
    private static func intersectingTileIndexBounds(
        mapBoundingRect bbox: MKMapRect,
        z: Int,
        geometryFlipped: Bool,
        padTiles: Int
    ) -> (x0: Int, x1: Int, y0: Int, y1: Int)? {
        guard z >= 0, z <= 31 else { return nil }
        let world = MKMapRect.world
        let n = Double(1 << z)
        guard n.isFinite, n > 0 else { return nil }
        let tileW = world.size.width / n
        let tileH = world.size.height / n

        let minMapX = bbox.origin.x
        let maxMapX = bbox.maxX
        let minMapY = bbox.origin.y
        let maxMapY = bbox.maxY

        let x0 = Int(floor((minMapX - world.origin.x) / tileW))
        let x1 = Int(floor((maxMapX - world.origin.x) / tileW))

        let y0: Int
        let y1: Int
        if geometryFlipped {
            let bottomEdge = world.origin.y + world.size.height - maxMapY
            let topEdge = world.origin.y + world.size.height - minMapY
            y0 = Int(floor(bottomEdge / tileH))
            y1 = Int(floor(topEdge / tileH))
        } else {
            y0 = Int(floor((minMapY - world.origin.y) / tileH))
            y1 = Int(floor((maxMapY - world.origin.y) / tileH))
        }

        let hi = (1 << z) - 1
        func clampRange(_ a: Int, _ b: Int) -> (Int, Int) {
            let loIdx = min(a, b)
            let hiIdx = max(a, b)
            return (min(max(loIdx, 0), hi), min(max(hiIdx, 0), hi))
        }
        let (cx0, cx1) = clampRange(x0, x1)
        let (cy0, cy1) = clampRange(y0, y1)
        guard cx0 <= cx1, cy0 <= cy1 else { return nil }
        let pad = max(0, padTiles)
        let px0 = max(0, cx0 - pad)
        let px1 = min(hi, cx1 + pad)
        let py0 = max(0, cy0 - pad)
        let py1 = min(hi, cy1 + pad)
        guard px0 <= px1, py0 <= py1 else { return nil }
        return (px0, px1, py0, py1)
    }
}
/// Background progressive tile generation: priority queues, source-chunk prewarm, lazy output tiles.
final class OverlayTileRuntimeScheduler {
    static let shared = OverlayTileRuntimeScheduler()

    enum JobPriority: Int, Comparable {
        case visibleExactTile = 0
        case sourceChunksForVisible = 1
        case sourceChunksPrewarm = 2
        case nearbyOutputTiles = 3
        case cheapFullLevel = 4

        static func < (lhs: JobPriority, rhs: JobPriority) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    enum JobKind: Hashable {
        case outputTile(z: Int, x: Int, y: Int, scale100: Int)
        case sourceChunk(chunkX: Int, chunkY: Int)
        case cheapFullLevel(z: Int)
    }

    struct Job: Hashable {
        let id: UUID
        let overlayID: UUID
        let revision: Int64
        let priority: JobPriority
        let kind: JobKind
        let viewportEpoch: UInt64

        init(
            overlayID: UUID,
            revision: Int64,
            priority: JobPriority,
            kind: JobKind,
            viewportEpoch: UInt64
        ) {
            self.id = UUID()
            self.overlayID = overlayID
            self.revision = revision
            self.priority = priority
            self.kind = kind
            self.viewportEpoch = viewportEpoch
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(overlayID)
            hasher.combine(revision)
            hasher.combine(kind)
        }

        static func == (lhs: Job, rhs: Job) -> Bool {
            lhs.overlayID == rhs.overlayID
                && lhs.revision == rhs.revision
                && lhs.kind == rhs.kind
        }
    }

    struct OverlayContext {
        let overlayID: UUID
        let revision: Int64
        let pyramidRoot: URL
        let corners: [CLLocationCoordinate2D]
        let bbox: MKMapRect
        let sourceRaster: Data
        let bakedFallback: UIImage
        let minZ: Int
        let maxZ: Int
        let tileContentScale: CGFloat
        let geometryFlipped: Bool
        let config: OverlayProgressiveTileConfig
        let sourceWidth: Int
        let sourceHeight: Int
    }

    struct ViewportSnapshot {
        let visibleMapRect: MKMapRect
        let currentZoom: Double
        let epoch: UInt64
    }

    private struct SourceChunkJobKey: Hashable {
        let overlayID: UUID
        let revision: Int64
        let chunkX: Int
        let chunkY: Int
    }

    private let queue = DispatchQueue(label: "snap-to-map.tile-runtime-scheduler", qos: .utility)
    private var contexts: [UUID: OverlayContext] = [:]
    private var viewports: [UUID: ViewportSnapshot] = [:]
    private var pendingJobs: [Job] = []
    private var activeSourceChunkJobs = 0
    private var activeOutputTileJobs = 0
    private var viewportEpoch: UInt64 = 0
    private weak var container: NSPersistentContainer?

    /// Per-tile runtime state (exact output tiles only).
    private var tileStates: [OverlayTileCoordinateKey: OverlayRuntimeTileState] = [:]
    /// Output tiles currently being generated (dedup guard).
    private var inFlightOutputTiles: Set<OverlayTileCoordinateKey> = []
    /// Source chunks currently being prewarmed (dedup guard).
    private var inFlightSourceChunks: Set<SourceChunkJobKey> = []
    /// Cheap full-level passes already completed for this overlay revision.
    private var completedCheapLevels: [UUID: Set<Int>] = [:]
    /// Tracks overlays where speculative prewarm is paused (save-after-edit transition).
    private var prewarmEnabledByOverlay: [UUID: Bool] = [:]
    /// Staged prewarm after save: visible output tiles → capped chunk waves → normal scheduling.
    private enum SaveTransitionPrewarmRecovery: Equatable {
        case outputOnly
        case chunkWaves
    }
    private var saveTransitionPrewarmRecovery: [UUID: SaveTransitionPrewarmRecovery] = [:]
    private static let saveTransitionChunkPrewarmCap = 6
    private static let normalPrewarmPendingQueueCap = 72
    private static let bakedFallbackMaxZOffsetFromMinZ = 1
    private static let saveTransitionBakedFallbackMaxZOffsetFromMinZ = 2
    /// Tracks overlays that had active work so we can detect idle transitions.
    private var overlayHadActiveWork: Set<UUID> = []

    private var sourceChunkCacheHits = 0
    private var sourceChunkCacheMisses = 0

    private init() {}

    func attach(container: NSPersistentContainer) {
        queue.async { [weak self] in
            self?.container = container
        }
    }

    struct WorkloadSnapshot {
        let pendingJobs: Int
        let activeOutputJobs: Int
        let activeChunkJobs: Int
        let inFlightTiles: Int
        let inFlightChunks: Int
        let prewarmEnabled: Bool
    }

    func debugWorkloadSnapshot(for overlayID: UUID) -> WorkloadSnapshot {
        var snap = WorkloadSnapshot(
            pendingJobs: 0,
            activeOutputJobs: 0,
            activeChunkJobs: 0,
            inFlightTiles: 0,
            inFlightChunks: 0,
            prewarmEnabled: true
        )
        queue.sync {
            snap = WorkloadSnapshot(
                pendingJobs: pendingJobs.filter { $0.overlayID == overlayID }.count,
                activeOutputJobs: activeOutputTileJobs,
                activeChunkJobs: activeSourceChunkJobs,
                inFlightTiles: inFlightOutputTiles.filter { $0.overlayID == overlayID }.count,
                inFlightChunks: inFlightSourceChunks.filter { $0.overlayID == overlayID }.count,
                prewarmEnabled: prewarmEnabledByOverlay[overlayID] ?? true
            )
        }
        return snap
    }

    /// Cancels speculative runtime work and disables prewarm during save-after-edit.
    func enterSaveTransition(overlayID: UUID) {
        queue.async { [weak self] in
            guard let self else { return }
            self.prewarmEnabledByOverlay[overlayID] = false
            self.saveTransitionPrewarmRecovery.removeValue(forKey: overlayID)
            let before = self.pendingJobs.count
            self.pendingJobs.removeAll { job in
                guard job.overlayID == overlayID else { return false }
                switch job.kind {
                case .outputTile:
                    return false
                case .sourceChunk, .cheapFullLevel:
                    return true
                }
            }
            self.pendingJobs.removeAll { job in
                job.overlayID == overlayID && job.priority >= .nearbyOutputTiles
            }
            if self.contexts[overlayID] != nil {
                self.contexts.removeValue(forKey: overlayID)
                self.viewports.removeValue(forKey: overlayID)
                self.tileStates = self.tileStates.filter { $0.key.overlayID != overlayID }
                self.inFlightOutputTiles = self.inFlightOutputTiles.filter { $0.overlayID != overlayID }
                self.inFlightSourceChunks = self.inFlightSourceChunks.filter { $0.overlayID != overlayID }
            }
            print("[TileProg] saveTransition.enter id=\(overlayID.uuidString.prefix(8)) cancelledPending=\(before - self.pendingJobs.count)")
        }
    }

    func enablePrewarmAfterSaveTransition(overlayID: UUID) {
        queue.async { [weak self] in
            guard let self else { return }
            self.prewarmEnabledByOverlay[overlayID] = true
            if let viewport = self.viewports[overlayID] {
                self.schedulePrewarmJobs(overlayID: overlayID, viewport: viewport)
            }
            self.drainQueueIfNeeded()
            print("[TileProg] saveTransition.prewarmEnabled id=\(overlayID.uuidString.prefix(8))")
        }
    }

    private func isPrewarmEnabled(for overlayID: UUID) -> Bool {
        prewarmEnabledByOverlay[overlayID] ?? true
    }

    func registerOverlay(context: OverlayContext) {
        queue.async { [weak self] in
            guard let self else { return }
            self.contexts[context.overlayID] = context
            print("[TileProg] register id=\(context.overlayID.uuidString.prefix(8)) minZ=\(context.minZ) maxZ=\(context.maxZ) rev=\(context.revision)")
        }
    }

    func unregisterOverlay(overlayID: UUID) {
        queue.async { [weak self] in
            guard let self else { return }
            self.contexts.removeValue(forKey: overlayID)
            self.viewports.removeValue(forKey: overlayID)
            self.pendingJobs.removeAll { $0.overlayID == overlayID }
            self.tileStates = self.tileStates.filter { $0.key.overlayID != overlayID }
            self.inFlightOutputTiles = self.inFlightOutputTiles.filter { $0.overlayID != overlayID }
            self.inFlightSourceChunks = self.inFlightSourceChunks.filter { $0.overlayID != overlayID }
            self.completedCheapLevels.removeValue(forKey: overlayID)
            self.prewarmEnabledByOverlay.removeValue(forKey: overlayID)
            self.saveTransitionPrewarmRecovery.removeValue(forKey: overlayID)
            self.overlayHadActiveWork.remove(overlayID)
            print("[TileProg] unregister id=\(overlayID.uuidString.prefix(8))")
        }
    }

    /// Query explicit runtime tile state for instrumentation / serve-side decisions.
    func runtimeTileState(
        overlayID: UUID,
        revision: Int64,
        z: Int,
        x: Int,
        y: Int,
        scale100: Int
    ) -> OverlayRuntimeTileState {
        let key = OverlayTileCoordinateKey(
            overlayID: overlayID,
            revision: revision,
            z: z,
            x: x,
            y: y,
            scale100: scale100
        )
        var result: OverlayRuntimeTileState = .missing
        queue.sync {
            result = self.tileStates[key] ?? .missing
        }
        return result
    }

    func updateViewport(
        overlayID: UUID,
        visibleMapRect: MKMapRect,
        currentZoom: Double
    ) {
        queue.async { [weak self] in
            guard let self, self.contexts[overlayID] != nil else { return }
            if let existing = self.viewports[overlayID],
               self.viewportApproximatelyEqual(existing, rect: visibleMapRect, zoom: currentZoom) {
                return
            }
            self.viewportEpoch &+= 1
            let snap = ViewportSnapshot(
                visibleMapRect: visibleMapRect,
                currentZoom: currentZoom,
                epoch: self.viewportEpoch
            )
            self.viewports[overlayID] = snap
            print("[TileProg] viewport.changed id=\(overlayID.uuidString.prefix(8)) epoch=\(snap.epoch) z_c=\(String(format: "%.2f", currentZoom))")
            let purged = self.purgeStaleViewportJobs(overlayID: overlayID, epoch: snap.epoch)
            if purged > 0 {
                print("[TileProg] viewport.purgedStale id=\(overlayID.uuidString.prefix(8)) count=\(purged) queue=\(self.pendingJobs.count)")
            }
            if self.isPrewarmEnabled(for: overlayID) {
                self.schedulePrewarmJobs(overlayID: overlayID, viewport: snap)
            } else {
                print("[TileProg] viewport.prewarmSkipped id=\(overlayID.uuidString.prefix(8)) saveTransition")
            }
            self.drainQueueIfNeeded()
        }
    }

    private func viewportApproximatelyEqual(_ snapshot: ViewportSnapshot, rect: MKMapRect, zoom: Double) -> Bool {
        guard abs(snapshot.currentZoom - zoom) < 0.08 else { return false }
        return relativeMapRectDelta(snapshot.visibleMapRect, rect) < 0.025
    }

    private func relativeMapRectDelta(_ a: MKMapRect, _ b: MKMapRect) -> Double {
        let dw = max(a.size.width, b.size.width, 1)
        let dh = max(a.size.height, b.size.height, 1)
        let dx = abs(a.origin.x - b.origin.x) / dw
        let dy = abs(a.origin.y - b.origin.y) / dh
        let dww = abs(a.size.width - b.size.width) / dw
        let dhh = abs(a.size.height - b.size.height) / dh
        return max(dx, dy, dww, dhh)
    }

    /// Priority 0: MapKit requested an exact tile that is missing on disk.
    func enqueueVisibleExactTile(
        overlayID: UUID,
        path: MKTileOverlayPath
    ) {
        queue.async { [weak self] in
            guard let self, let ctx = self.contexts[overlayID] else { return }
            let scale100 = Int((path.contentScaleFactor * 100).rounded())
            let key = OverlayTileCoordinateKey(
                overlayID: overlayID,
                revision: ctx.revision,
                z: path.z,
                x: path.x,
                y: path.y,
                scale100: scale100
            )
            if self.tileStates[key] == .ready || self.inFlightOutputTiles.contains(key) {
                print("[TileProg] enqueue.dedup id=\(overlayID.uuidString.prefix(8)) z=\(path.z) x=\(path.x) y=\(path.y) state=\(String(describing: self.tileStates[key])) inFlight=\(self.inFlightOutputTiles.contains(key))")
                return
            }
            if self.tileExists(context: ctx, z: path.z, x: path.x, y: path.y) {
                self.tileStates[key] = .ready
                print("[TileProg] enqueue.skipReadyOnDisk id=\(overlayID.uuidString.prefix(8)) z=\(path.z) x=\(path.x) y=\(path.y)")
                return
            }
            let epoch = self.viewports[overlayID]?.epoch ?? self.viewportEpoch
            let job = Job(
                overlayID: overlayID,
                revision: ctx.revision,
                priority: .visibleExactTile,
                kind: .outputTile(z: path.z, x: path.x, y: path.y, scale100: scale100),
                viewportEpoch: epoch
            )
            print("[TileProg] enqueue.visibleExact id=\(overlayID.uuidString.prefix(8)) z=\(path.z) x=\(path.x) y=\(path.y) scale100=\(scale100)")
            self.enqueue(job)
            self.drainQueueIfNeeded()
        }
    }

    func handleMemoryWarning() {
        queue.async { [weak self] in
            guard let self else { return }
            OverlayTileRuntimeInstrumentation.recordMemoryWarning()
            let before = self.pendingJobs.count
            self.pendingJobs.removeAll { $0.priority >= .sourceChunksPrewarm }
            OverlayMetalTilePipeline.clearSessionCache()
            print("[TileProg] memoryWarning cancelledSpeculative=\(before - self.pendingJobs.count) queue=\(self.pendingJobs.count)")
            self.recordQueueInstrumentation()
        }
    }

    // MARK: - Private scheduling

    private func enqueue(_ job: Job) {
        if case let .sourceChunk(cx, cy) = job.kind {
            let chunkKey = SourceChunkJobKey(
                overlayID: job.overlayID,
                revision: job.revision,
                chunkX: cx,
                chunkY: cy
            )
            if inFlightSourceChunks.contains(chunkKey) {
                print("[TileProg] enqueue.suppressedChunk id=\(job.overlayID.uuidString.prefix(8)) cx=\(cx) cy=\(cy)")
                return
            }
        }
        if case let .outputTile(z, x, y, scale100) = job.kind {
            let key = OverlayTileCoordinateKey(
                overlayID: job.overlayID,
                revision: job.revision,
                z: z,
                x: x,
                y: y,
                scale100: scale100
            )
            if tileStates[key] == .ready || inFlightOutputTiles.contains(key) {
                print("[TileProg] enqueue.suppressed id=\(job.overlayID.uuidString.prefix(8)) z=\(z) x=\(x) y=\(y) state=\(String(describing: tileStates[key])) inFlight=\(inFlightOutputTiles.contains(key))")
                return
            }
        }
        if let existingIndex = pendingJobs.firstIndex(where: { $0 == job }) {
            let existing = pendingJobs[existingIndex]
            if job.priority < existing.priority {
                pendingJobs[existingIndex] = job
                pendingJobs.sort { $0.priority < $1.priority }
                print("[TileProg] enqueue.promoted id=\(job.overlayID.uuidString.prefix(8)) kind=\(job.kind) pri=\(job.priority.rawValue)")
            } else {
                print("[TileProg] enqueue.coalesced id=\(job.overlayID.uuidString.prefix(8)) kind=\(job.kind) pri=\(job.priority.rawValue)")
            }
            return
        }
        pendingJobs.append(job)
        pendingJobs.sort { $0.priority < $1.priority }
        print("[TileProg] enqueue id=\(job.overlayID.uuidString.prefix(8)) kind=\(job.kind) pri=\(job.priority.rawValue) queue=\(pendingJobs.count)")
    }

    private func schedulePrewarmJobs(overlayID: UUID, viewport: ViewportSnapshot) {
        guard let ctx = contexts[overlayID] else { return }
        guard isPrewarmEnabled(for: overlayID) else {
            print("[TileProg] prewarm.disabled id=\(overlayID.uuidString.prefix(8))")
            return
        }
        let recovery = saveTransitionPrewarmRecovery[overlayID]
        let zc = Int(floor(viewport.currentZoom))
        let targetWarmZ = min(zc + ctx.config.prewarmLookaheadZooms, ctx.maxZ)
        let margin = ctx.config.prewarmMarginScreens
        let prewarmRect = expandedMapRect(viewport.visibleMapRect, marginScreens: margin)
        let overlayPrewarm = prewarmRect.intersection(ctx.bbox)
        guard !overlayPrewarm.isNull, !overlayPrewarm.isEmpty else { return }

        var prewarmBudget: Int? = recovery == nil
            ? max(0, Self.normalPrewarmPendingQueueCap - pendingJobs.count)
            : nil
        if let prewarmBudget, prewarmBudget == 0 {
            print("[TileProg] prewarm.queueCap id=\(overlayID.uuidString.prefix(8)) queue=\(pendingJobs.count) cap=\(Self.normalPrewarmPendingQueueCap)")
            return
        }

        let recoveryLabel = recovery.map { phase -> String in
            switch phase {
            case .outputOnly: return "outputOnly"
            case .chunkWaves: return "chunkWaves"
            }
        } ?? "full"
        print(
            "[TileProg] viewport id=\(overlayID.uuidString.prefix(8)) z_c=\(String(format: "%.2f", viewport.currentZoom)) targetWarmZ=\(targetWarmZ) recovery=\(recoveryLabel) visible=(\(Int(viewport.visibleMapRect.origin.x)),\(Int(viewport.visibleMapRect.origin.y)),\(Int(viewport.visibleMapRect.size.width)),\(Int(viewport.visibleMapRect.size.height))) prewarm=(\(Int(overlayPrewarm.origin.x)),\(Int(overlayPrewarm.origin.y)),\(Int(overlayPrewarm.size.width)),\(Int(overlayPrewarm.size.height))) queue=\(pendingJobs.count)"
        )

        if targetWarmZ <= zc { return }

        let chunkCap: Int? = {
            switch recovery {
            case .none: return nil
            case .outputOnly: return 0
            case .chunkWaves: return Self.saveTransitionChunkPrewarmCap
            }
        }()
        if chunkCap != 0 {
            let chunkLimit: Int? = {
                if let chunkCap, let prewarmBudget { return min(chunkCap, prewarmBudget) }
                return chunkCap
            }()
            let chunksEnqueued = enqueueMissingSourceChunkJobs(
                overlayID: overlayID,
                viewport: viewport,
                context: ctx,
                overlayPrewarm: overlayPrewarm,
                targetWarmZ: targetWarmZ,
                zc: zc,
                maxEnqueue: chunkLimit
            )
            if prewarmBudget != nil {
                prewarmBudget = max(0, prewarmBudget! - chunksEnqueued)
            }
            if recovery == .chunkWaves, chunksEnqueued > 0 {
                print("[TileProg] saveTransition.chunkWave id=\(overlayID.uuidString.prefix(8)) enqueued=\(chunksEnqueued) cap=\(Self.saveTransitionChunkPrewarmCap)")
            }
        }

        if zc + 1 <= ctx.maxZ, prewarmBudget != 0 {
            let tiles = outputTileCoords(intersecting: overlayPrewarm, z: zc + 1, geometryFlipped: ctx.geometryFlipped)
            for t in tiles {
                if let prewarmBudget, prewarmBudget <= 0 { break }
                if tileExists(context: ctx, z: zc + 1, x: t.x, y: t.y) { continue }
                let scale100 = Int((ctx.tileContentScale * 100).rounded())
                let key = OverlayTileCoordinateKey(
                    overlayID: overlayID,
                    revision: ctx.revision,
                    z: zc + 1,
                    x: t.x,
                    y: t.y,
                    scale100: scale100
                )
                if inFlightOutputTiles.contains(key) || tileStates[key] == .ready { continue }
                enqueue(Job(
                    overlayID: overlayID,
                    revision: ctx.revision,
                    priority: .nearbyOutputTiles,
                    kind: .outputTile(z: zc + 1, x: t.x, y: t.y, scale100: Int((ctx.tileContentScale * 100).rounded())),
                    viewportEpoch: viewport.epoch
                ))
                if prewarmBudget != nil {
                    prewarmBudget! -= 1
                }
            }
        }

        guard recovery == nil else { return }
        if prewarmBudget == 0 { return }

        let comfortDepth = ctx.config.earlyComfortDepth
        for dz in 1...comfortDepth {
            if prewarmBudget == 0 { break }
            let z = zc + dz
            guard z <= ctx.maxZ else { break }
            let cells = outputTileCoords(intersecting: ctx.bbox, z: z, geometryFlipped: ctx.geometryFlipped)
            if cells.count <= ctx.config.cheapLevelTileLimit {
                if completedCheapLevels[overlayID]?.contains(z) == true { continue }
                enqueue(Job(
                    overlayID: overlayID,
                    revision: ctx.revision,
                    priority: .cheapFullLevel,
                    kind: .cheapFullLevel(z: z),
                    viewportEpoch: viewport.epoch
                ))
                if prewarmBudget != nil {
                    prewarmBudget! -= 1
                }
            }
        }
    }

    private func preferBakedFallbackFirst(for ctx: OverlayContext, z: Int) -> Bool {
        if z <= ctx.minZ + Self.bakedFallbackMaxZOffsetFromMinZ { return true }
        if saveTransitionPrewarmRecovery[ctx.overlayID] != nil,
           z <= ctx.minZ + Self.saveTransitionBakedFallbackMaxZOffsetFromMinZ {
            return true
        }
        return false
    }

    @discardableResult
    private func enqueueMissingSourceChunkJobs(
        overlayID: UUID,
        viewport: ViewportSnapshot,
        context ctx: OverlayContext,
        overlayPrewarm: MKMapRect,
        targetWarmZ: Int,
        zc: Int,
        maxEnqueue: Int?
    ) -> Int {
        var enqueued = 0
        chunkLoop: for warmZ in (zc + 1)...targetWarmZ {
            let chunkKeys = sourceChunkKeysForMapRect(
                overlayPrewarm,
                z: warmZ,
                context: ctx
            )
            for key in chunkKeys {
                if let maxEnqueue, enqueued >= maxEnqueue { break chunkLoop }
                let diskURL = OverlayLibrary.sourceChunkCacheFileURL(
                    pyramidRoot: ctx.pyramidRoot,
                    chunkX: key.chunkX,
                    chunkY: key.chunkY
                )
                if FileManager.default.fileExists(atPath: diskURL.path) {
                    sourceChunkCacheHits += 1
                    continue
                }
                let chunkJobKey = SourceChunkJobKey(
                    overlayID: overlayID,
                    revision: ctx.revision,
                    chunkX: key.chunkX,
                    chunkY: key.chunkY
                )
                if inFlightSourceChunks.contains(chunkJobKey) { continue }
                sourceChunkCacheMisses += 1
                enqueue(Job(
                    overlayID: overlayID,
                    revision: ctx.revision,
                    priority: warmZ <= zc + 1 ? .sourceChunksPrewarm : .sourceChunksPrewarm,
                    kind: .sourceChunk(chunkX: key.chunkX, chunkY: key.chunkY),
                    viewportEpoch: viewport.epoch
                ))
                enqueued += 1
            }
        }
        return enqueued
    }

    private func advanceSaveTransitionPrewarmIfIdle(overlayID: UUID) {
        guard let phase = saveTransitionPrewarmRecovery[overlayID],
              let viewport = viewports[overlayID] else { return }
        switch phase {
        case .outputOnly:
            saveTransitionPrewarmRecovery[overlayID] = .chunkWaves
            print("[TileProg] saveTransition.prewarmPhase chunkWaves id=\(overlayID.uuidString.prefix(8))")
            schedulePrewarmJobs(overlayID: overlayID, viewport: viewport)
            drainQueueIfNeeded()
        case .chunkWaves:
            guard let ctx = contexts[overlayID] else { return }
            let zc = Int(floor(viewport.currentZoom))
            let targetWarmZ = min(zc + ctx.config.prewarmLookaheadZooms, ctx.maxZ)
            let overlayPrewarm = expandedMapRect(
                viewport.visibleMapRect,
                marginScreens: ctx.config.prewarmMarginScreens
            ).intersection(ctx.bbox)
            let enqueued = enqueueMissingSourceChunkJobs(
                overlayID: overlayID,
                viewport: viewport,
                context: ctx,
                overlayPrewarm: overlayPrewarm,
                targetWarmZ: targetWarmZ,
                zc: zc,
                maxEnqueue: Self.saveTransitionChunkPrewarmCap
            )
            if enqueued > 0 {
                print("[TileProg] saveTransition.chunkWave id=\(overlayID.uuidString.prefix(8)) enqueued=\(enqueued) cap=\(Self.saveTransitionChunkPrewarmCap)")
                drainQueueIfNeeded()
                return
            }
            saveTransitionPrewarmRecovery.removeValue(forKey: overlayID)
            print("[TileProg] saveTransition.prewarmPhase complete id=\(overlayID.uuidString.prefix(8))")
            schedulePrewarmJobs(overlayID: overlayID, viewport: viewport)
            drainQueueIfNeeded()
        }
    }

    /// Drops speculative jobs tied to an older viewport epoch (avoids draining them one-by-one via recursive scheduling).
    private func purgeStaleViewportJobs(overlayID: UUID, epoch: UInt64) -> Int {
        let before = pendingJobs.count
        pendingJobs.removeAll { job in
            guard job.overlayID == overlayID else { return false }
            guard job.viewportEpoch != epoch else { return false }
            switch job.priority {
            case .visibleExactTile:
                return false
            case .sourceChunksForVisible, .sourceChunksPrewarm, .nearbyOutputTiles, .cheapFullLevel:
                return true
            }
        }
        return before - pendingJobs.count
    }

    private func purgeOrphanPendingJobs() -> Int {
        let before = pendingJobs.count
        pendingJobs.removeAll { contexts[$0.overlayID] == nil }
        return before - pendingJobs.count
    }

    private func drainQueueIfNeeded() {
        if purgeOrphanPendingJobs() > 0 {
            print("[TileProg] queue.purgedOrphans count=\(pendingJobs.count)")
        }
        while activeSourceChunkJobs < (contexts.values.first?.config.maxConcurrentSourceChunkJobs ?? 1) {
            guard let job = pendingJobs.first(where: { job in
                switch job.kind {
                case .sourceChunk:
                    return activeSourceChunkJobs < (contexts[job.overlayID]?.config.maxConcurrentSourceChunkJobs ?? 1)
                case .outputTile, .cheapFullLevel:
                    return false
                }
            }) else { break }
            pendingJobs.removeAll { $0 == job }
            activeSourceChunkJobs += 1
            runSourceChunkJob(job)
        }

        while activeOutputTileJobs < (contexts.values.first?.config.maxConcurrentOutputTileJobs ?? 1) {
            guard let job = pendingJobs.first(where: { job in
                switch job.kind {
                case .outputTile, .cheapFullLevel:
                    return activeOutputTileJobs < (contexts[job.overlayID]?.config.maxConcurrentOutputTileJobs ?? 1)
                case .sourceChunk:
                    return false
                }
            }) else { break }
            pendingJobs.removeAll { $0 == job }
            activeOutputTileJobs += 1
            runOutputJob(job)
        }
        recordQueueInstrumentation()
        checkOverlayIdleStates()
    }

    private func recordQueueInstrumentation() {
        OverlayTileRuntimeInstrumentation.recordQueueSample(
            pending: pendingJobs.count,
            activeOutput: activeOutputTileJobs,
            activeChunks: activeSourceChunkJobs,
            inFlightTiles: inFlightOutputTiles.count,
            inFlightChunks: inFlightSourceChunks.count
        )
    }

    private func overlayHasActiveWork(_ overlayID: UUID) -> Bool {
        if pendingJobs.contains(where: { $0.overlayID == overlayID }) { return true }
        if inFlightOutputTiles.contains(where: { $0.overlayID == overlayID }) { return true }
        if inFlightSourceChunks.contains(where: { $0.overlayID == overlayID }) { return true }
        if activeOutputTileJobs > 0 || activeSourceChunkJobs > 0,
           contexts[overlayID] != nil,
           contexts.count == 1 {
            return true
        }
        return false
    }

    private func checkOverlayIdleStates() {
        let overlayIDs = Array(contexts.keys)
        var idleAdvanceCandidates: [UUID] = []
        for overlayID in overlayIDs {
            let active = overlayHasActiveWork(overlayID)
            if active {
                overlayHadActiveWork.insert(overlayID)
                continue
            }
            guard overlayHadActiveWork.remove(overlayID) != nil else { continue }
            OverlayTileRuntimeInstrumentation.recordQueueDrain(
                overlayID: overlayID,
                pending: pendingJobs.count,
                inFlightTiles: inFlightOutputTiles.count,
                inFlightChunks: inFlightSourceChunks.count
            )
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .overlayProgressiveTilesQueueDidDrain,
                    object: nil,
                    userInfo: ["overlayID": overlayID.uuidString]
                )
            }
            idleAdvanceCandidates.append(overlayID)
        }
        for overlayID in idleAdvanceCandidates {
            advanceSaveTransitionPrewarmIfIdle(overlayID: overlayID)
        }
    }

    private func runSourceChunkJob(_ job: Job) {
        guard let ctx = contexts[job.overlayID], ctx.revision == job.revision else {
            activeSourceChunkJobs = max(0, activeSourceChunkJobs - 1)
            return
        }
        if job.priority >= .sourceChunksPrewarm,
           let vp = viewports[job.overlayID],
           vp.epoch != job.viewportEpoch {
            activeSourceChunkJobs = max(0, activeSourceChunkJobs - 1)
            return
        }
        guard case let .sourceChunk(cx, cy) = job.kind else {
            activeSourceChunkJobs = max(0, activeSourceChunkJobs - 1)
            return
        }
        let chunkKey = SourceChunkJobKey(
            overlayID: job.overlayID,
            revision: job.revision,
            chunkX: cx,
            chunkY: cy
        )
        if inFlightSourceChunks.contains(chunkKey) {
            activeSourceChunkJobs = max(0, activeSourceChunkJobs - 1)
            return
        }
        inFlightSourceChunks.insert(chunkKey)
        let started = CFAbsoluteTimeGetCurrent()
        let diskURL = OverlayLibrary.sourceChunkCacheFileURL(pyramidRoot: ctx.pyramidRoot, chunkX: cx, chunkY: cy)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            defer {
                self?.queue.async {
                    guard let self else { return }
                    self.inFlightSourceChunks.remove(chunkKey)
                    self.activeSourceChunkJobs = max(0, self.activeSourceChunkJobs - 1)
                    self.drainQueueIfNeeded()
                }
            }
            do {
                let wrote = try OverlayMetalTilePipeline.persistSourceChunkIfNeeded(
                    sourceRaster: ctx.sourceRaster,
                    chunkKey: OverlayMetalTilePipeline.ChunkKey(chunkX: cx, chunkY: cy),
                    chunkSide: ctx.config.sourceChunkSize,
                    sourceWidth: ctx.sourceWidth,
                    sourceHeight: ctx.sourceHeight,
                    diskURL: diskURL
                )
                let elapsed = CFAbsoluteTimeGetCurrent() - started
                OverlayTileRuntimeInstrumentation.recordSourceChunkLoad(
                    overlayID: job.overlayID,
                    chunkX: cx,
                    chunkY: cy,
                    fromDisk: !wrote
                )
                print("[TileProg] chunkPrewarm id=\(job.overlayID.uuidString.prefix(8)) cx=\(cx) cy=\(cy) wrote=\(wrote) duration=\(String(format: "%.2f", elapsed))s")
            } catch {
                print("[TileProg] chunkPrewarm.fail id=\(job.overlayID.uuidString.prefix(8)) cx=\(cx) cy=\(cy) error=\(error)")
            }
        }
    }

    private func runOutputJob(_ job: Job) {
        guard let ctx = contexts[job.overlayID], ctx.revision == job.revision else {
            activeOutputTileJobs = max(0, activeOutputTileJobs - 1)
            return
        }
        if job.priority >= .nearbyOutputTiles,
           let vp = viewports[job.overlayID],
           vp.epoch != job.viewportEpoch {
            activeOutputTileJobs = max(0, activeOutputTileJobs - 1)
            return
        }

        let finish: () -> Void = { [weak self] in
            self?.queue.async {
                guard let self else { return }
                self.activeOutputTileJobs = max(0, self.activeOutputTileJobs - 1)
                self.drainQueueIfNeeded()
            }
        }

        switch job.kind {
        case let .outputTile(z, x, y, scale100):
            let scale = CGFloat(scale100) / 100
            let key = OverlayTileCoordinateKey(
                overlayID: job.overlayID,
                revision: job.revision,
                z: z,
                x: x,
                y: y,
                scale100: scale100
            )
            if tileStates[key] == .ready || inFlightOutputTiles.contains(key) {
                print("[TileProg] dequeue.skipDuplicate id=\(job.overlayID.uuidString.prefix(8)) z=\(z) x=\(x) y=\(y)")
                finish()
                return
            }
            if tileExists(context: ctx, z: z, x: x, y: y) {
                tileStates[key] = .ready
                print("[TileProg] dequeue.skipReadyOnDisk id=\(job.overlayID.uuidString.prefix(8)) z=\(z) x=\(x) y=\(y)")
                finish()
                return
            }
            inFlightOutputTiles.insert(key)
            tileStates[key] = .generating
            OverlayTileRuntimeInstrumentation.recordTileGenerationStart(
                overlayID: job.overlayID,
                z: z,
                x: x,
                y: y
            )
            print("[TileProg] tileGen.start id=\(job.overlayID.uuidString.prefix(8)) z=\(z) x=\(x) y=\(y) pri=\(job.priority.rawValue)")
            generateAndPersistTile(
                context: ctx,
                tileKey: key,
                z: z,
                x: x,
                y: y,
                contentScale: scale,
                priority: job.priority,
                preferBakedFallbackFirst: preferBakedFallbackFirst(for: ctx, z: z),
                completion: finish
            )
        case let .cheapFullLevel(z):
            let cells = outputTileCoords(intersecting: ctx.bbox, z: z, geometryFlipped: ctx.geometryFlipped)
            generateCheapLevel(context: ctx, z: z, cells: cells) { [weak self] in
                self?.queue.async {
                    self?.completedCheapLevels[job.overlayID, default: []].insert(z)
                }
                finish()
            }
        case .sourceChunk:
            finish()
        }
    }

    private func generateCheapLevel(
        context ctx: OverlayContext,
        z: Int,
        cells: [(x: Int, y: Int)],
        completion: @escaping () -> Void
    ) {
        DispatchQueue.global(qos: .utility).async {
            defer { completion() }
            for cell in cells {
                let scale100 = Int((ctx.tileContentScale * 100).rounded())
                let key = OverlayTileCoordinateKey(
                    overlayID: ctx.overlayID,
                    revision: ctx.revision,
                    z: z,
                    x: cell.x,
                    y: cell.y,
                    scale100: scale100
                )
                var shouldRun = false
                self.queue.sync {
                    if self.tileStates[key] == .ready || self.inFlightOutputTiles.contains(key) {
                        shouldRun = false
                    } else if self.tileExists(context: ctx, z: z, x: cell.x, y: cell.y) {
                        self.tileStates[key] = .ready
                        shouldRun = false
                    } else {
                        self.inFlightOutputTiles.insert(key)
                        self.tileStates[key] = .generating
                        shouldRun = true
                    }
                }
                guard shouldRun else { continue }
                let sem = DispatchSemaphore(value: 0)
                self.generateAndPersistTile(
                    context: ctx,
                    tileKey: key,
                    z: z,
                    x: cell.x,
                    y: cell.y,
                    contentScale: ctx.tileContentScale,
                    priority: .cheapFullLevel,
                    preferBakedFallbackFirst: self.preferBakedFallbackFirst(for: ctx, z: z)
                ) { sem.signal() }
                sem.wait()
            }
        }
    }

    private func generateAndPersistTile(
        context ctx: OverlayContext,
        tileKey: OverlayTileCoordinateKey,
        z: Int,
        x: Int,
        y: Int,
        contentScale: CGFloat,
        priority: JobPriority,
        preferBakedFallbackFirst: Bool = false,
        completion: @escaping () -> Void
    ) {
        DispatchQueue.global(qos: priority == .visibleExactTile ? .userInitiated : .utility).async {
            defer { completion() }
            autoreleasepool {
                let started = CFAbsoluteTimeGetCurrent()
                let path = MKTileOverlayPath(x: x, y: y, z: z, contentScaleFactor: contentScale)
                if self.tileExists(context: ctx, z: z, x: x, y: y) {
                    self.queue.async {
                        self.inFlightOutputTiles.remove(tileKey)
                        self.tileStates[tileKey] = .ready
                    }
                    print("[TileProg] tileGen.skipExists id=\(ctx.overlayID.uuidString.prefix(8)) z=\(z) x=\(x) y=\(y)")
                    return
                }
                let tileRect = BakedImageMapTileOverlay.mercatorMapRectForOfflinePyramid(
                    path: path,
                    geometryFlipped: ctx.geometryFlipped
                )
                let clipped = ctx.bbox.intersection(tileRect)
                guard !clipped.isNull, !clipped.isEmpty else {
                    self.queue.async {
                        self.inFlightOutputTiles.remove(tileKey)
                        self.tileStates[tileKey] = .failed
                    }
                    print("[TileProg] tileGen.emptyClip id=\(ctx.overlayID.uuidString.prefix(8)) z=\(z) x=\(x) y=\(y)")
                    return
                }

                let bakedCG = OverlayMapBake.normalizedCGImage(from: ctx.bakedFallback)
                if preferBakedFallbackFirst,
                   let data = OverlayTileRenderer.mercatorTileHEIFDataFromBakedFallback(
                    bakedFallbackCG: bakedCG,
                    tileRect: tileRect,
                    bbox: ctx.bbox,
                    clipped: clipped,
                    tileSize: OverlayLibrary.logicalTileSize,
                    scale: contentScale
                   ) {
                    let url = OverlayLibrary.tileDataFileURL(pyramidRoot: ctx.pyramidRoot, path: path)
                    do {
                        try OverlayLibrary.atomicWriteTileData(data, to: url)
                    } catch {
                        self.queue.async {
                            self.inFlightOutputTiles.remove(tileKey)
                            self.tileStates[tileKey] = .failed
                        }
                        print("[TileProg] tileGen.writeFail id=\(ctx.overlayID.uuidString.prefix(8)) z=\(z) x=\(x) y=\(y) error=\(error)")
                        return
                    }
                    let elapsed = CFAbsoluteTimeGetCurrent() - started
                    print("[TileProg] tileGen.bakedFallback id=\(ctx.overlayID.uuidString.prefix(8)) z=\(z) x=\(x) y=\(y) duration=\(String(format: "%.2f", elapsed))s")
                    self.queue.async {
                        self.inFlightOutputTiles.remove(tileKey)
                        self.tileStates[tileKey] = .ready
                    }
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(
                            name: .overlayProgressiveTilesDidUpdate,
                            object: nil,
                            userInfo: [
                                "overlayID": ctx.overlayID.uuidString,
                                "revision": ctx.revision,
                                "z": z,
                                "x": x,
                                "y": y,
                                "scale100": tileKey.scale100,
                                "queueIdle": false,
                            ]
                        )
                    }
                    return
                }

                let footprint = self.estimateSourceFootprint(context: ctx, tileRect: tileRect, clipped: clipped, contentScale: contentScale)
                let chunkKeys = OverlayMetalTilePipeline.chunkKeysIntersecting(
                    sourceRect: footprint,
                    sourceWidth: ctx.sourceWidth,
                    sourceHeight: ctx.sourceHeight,
                    chunkSide: ctx.config.sourceChunkSize
                )

                let thumbScope = "\(ctx.overlayID.uuidString)-\(ctx.revision)-runtime"
                OverlayMapBake.beginThumbnailCacheScope(thumbScope)
                defer { OverlayMapBake.endThumbnailCacheScope() }

                let session: OverlayMetalTilePipeline.ChunkedSourceSession
                do {
                    session = try OverlayMetalTilePipeline.partialSourceSession(
                        sourceRaster: ctx.sourceRaster,
                        corners: ctx.corners,
                        mercatorPixelWidth: ctx.sourceWidth,
                        mercatorPixelHeight: ctx.sourceHeight,
                        chunkKeys: chunkKeys,
                        diskCacheRoot: ctx.pyramidRoot,
                        chunkSide: ctx.config.sourceChunkSize,
                        cacheScope: thumbScope
                    )
                } catch {
                    self.queue.async {
                        self.inFlightOutputTiles.remove(tileKey)
                        self.tileStates[tileKey] = .failed
                    }
                    print("[TileProg] tileGen.sessionFail id=\(ctx.overlayID.uuidString.prefix(8)) z=\(z) error=\(error)")
                    return
                }

                let request = OverlayTileRenderer.SourceTileRequest(
                    sourceRaster: ctx.sourceRaster,
                    corners: ctx.corners,
                    mercatorPixelWidth: ctx.sourceWidth,
                    mercatorPixelHeight: ctx.sourceHeight,
                    tileRect: tileRect,
                    bbox: ctx.bbox,
                    clipped: clipped,
                    tileSize: OverlayLibrary.logicalTileSize,
                    contentScale: contentScale,
                    thumbnailCacheScope: thumbScope,
                    metalSourceSession: session,
                    requestedZ: z,
                    sourceZ: z
                )
                guard let data = OverlayTileRenderer.mercatorTileHEIFData(from: request)
                        ?? OverlayTileRenderer.mercatorTileHEIFDataFromBakedFallback(
                            bakedFallbackCG: bakedCG,
                            tileRect: tileRect,
                            bbox: ctx.bbox,
                            clipped: clipped,
                            tileSize: OverlayLibrary.logicalTileSize,
                            scale: contentScale
                        ) else {
                    self.queue.async {
                        self.inFlightOutputTiles.remove(tileKey)
                        self.tileStates[tileKey] = .failed
                    }
                    print("[TileProg] tileGen.nil id=\(ctx.overlayID.uuidString.prefix(8)) z=\(z) x=\(x) y=\(y)")
                    return
                }

                let url = OverlayLibrary.tileDataFileURL(pyramidRoot: ctx.pyramidRoot, path: path)
                do {
                    try OverlayLibrary.atomicWriteTileData(data, to: url)
                } catch {
                    self.queue.async {
                        self.inFlightOutputTiles.remove(tileKey)
                        self.tileStates[tileKey] = .failed
                    }
                    print("[TileProg] tileGen.writeFail id=\(ctx.overlayID.uuidString.prefix(8)) z=\(z) x=\(x) y=\(y) error=\(error)")
                    return
                }

                let elapsed = CFAbsoluteTimeGetCurrent() - started
                if let cg = CGImageSourceCreateWithData(data as CFData, nil),
                   let img = CGImageSourceCreateImageAtIndex(cg, 0, nil) {
                    print("[TileProg] tileGen.complete id=\(ctx.overlayID.uuidString.prefix(8)) pri=\(priority.rawValue) z=\(z) x=\(x) y=\(y) output=\(img.width)x\(img.height) duration=\(String(format: "%.2f", elapsed))s write=\(url.lastPathComponent)")
                } else {
                    print("[TileProg] tileGen.complete id=\(ctx.overlayID.uuidString.prefix(8)) pri=\(priority.rawValue) z=\(z) x=\(x) y=\(y) duration=\(String(format: "%.2f", elapsed))s write=\(url.lastPathComponent)")
                }

                self.queue.async {
                    self.inFlightOutputTiles.remove(tileKey)
                    self.tileStates[tileKey] = .ready
                }

                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: .overlayProgressiveTilesDidUpdate,
                        object: nil,
                        userInfo: [
                            "overlayID": ctx.overlayID.uuidString,
                            "revision": ctx.revision,
                            "z": z,
                            "x": x,
                            "y": y,
                            "scale100": tileKey.scale100,
                            "queueIdle": false,
                        ]
                    )
                }
            }
        }
    }

    // MARK: - Geometry helpers

    private func expandedMapRect(_ rect: MKMapRect, marginScreens: Double) -> MKMapRect {
        let m = max(0, marginScreens)
        let mx = rect.size.width * m
        let my = rect.size.height * m
        return MKMapRect(
            origin: MKMapPoint(x: rect.origin.x - mx, y: rect.origin.y - my),
            size: MKMapSize(width: rect.size.width + 2 * mx, height: rect.size.height + 2 * my)
        ).intersection(MKMapRect.world)
    }

    private func outputTileCoords(
        intersecting mapRect: MKMapRect,
        z: Int,
        geometryFlipped: Bool
    ) -> [(x: Int, y: Int)] {
        guard let xy = OverlayTilePyramidIntersectingBounds.bounds(
            mapBoundingRect: mapRect,
            z: z,
            geometryFlipped: geometryFlipped,
            padTiles: 0
        ) else { return [] }
        var out: [(Int, Int)] = []
        for x in xy.x0...xy.x1 {
            for y in xy.y0...xy.y1 {
                out.append((x, y))
            }
        }
        return out
    }

    private func sourceChunkKeysForMapRect(
        _ mapRect: MKMapRect,
        z: Int,
        context ctx: OverlayContext
    ) -> Set<OverlayMetalTilePipeline.ChunkKey> {
        var union = CGRect.null
        let tiles = outputTileCoords(intersecting: mapRect, z: z, geometryFlipped: ctx.geometryFlipped)
        for t in tiles {
            let path = MKTileOverlayPath(x: t.x, y: t.y, z: z, contentScaleFactor: ctx.tileContentScale)
            let tileRect = BakedImageMapTileOverlay.mercatorMapRectForOfflinePyramid(
                path: path,
                geometryFlipped: ctx.geometryFlipped
            )
            let clipped = ctx.bbox.intersection(tileRect)
            guard !clipped.isNull, !clipped.isEmpty else { continue }
            let footprint = estimateSourceFootprint(
                context: ctx,
                tileRect: tileRect,
                clipped: clipped,
                contentScale: ctx.tileContentScale
            )
            union = union.isNull ? footprint : union.union(footprint)
        }
        return OverlayMetalTilePipeline.chunkKeysIntersecting(
            sourceRect: union,
            sourceWidth: ctx.sourceWidth,
            sourceHeight: ctx.sourceHeight,
            chunkSide: ctx.config.sourceChunkSize
        )
    }

    private func estimateSourceFootprint(
        context ctx: OverlayContext,
        tileRect: MKMapRect,
        clipped: MKMapRect,
        contentScale: CGFloat
    ) -> CGRect {
        guard let layout = OverlayMapBake.mercatorTileLayout(
            mercatorWidth: ctx.sourceWidth,
            mercatorHeight: ctx.sourceHeight,
            tileRect: tileRect,
            bbox: ctx.bbox,
            clipped: clipped,
            tileSize: OverlayLibrary.logicalTileSize,
            contentScale: contentScale
        ) else { return .zero }
        let basis = layout.destinationBasis()
        return OverlayMetalTilePipeline.estimateSourceFootprintBBox(
            outputWidth: layout.outputWidth,
            outputHeight: layout.outputHeight,
            destOrigin: basis.origin,
            destStepX: basis.stepX,
            destStepY: basis.stepY,
            destToSource: OverlayTileHomography.destToSourceMatrix(
                mercatorPixelWidth: ctx.sourceWidth,
                mercatorPixelHeight: ctx.sourceHeight,
                sourcePixelWidth: ctx.sourceWidth,
                sourcePixelHeight: ctx.sourceHeight,
                corners: ctx.corners
            ) ?? matrix_identity_float3x3,
            sourceWidth: ctx.sourceWidth,
            sourceHeight: ctx.sourceHeight
        )
    }

    private func tileExists(context ctx: OverlayContext, z: Int, x: Int, y: Int) -> Bool {
        let path = MKTileOverlayPath(x: x, y: y, z: z, contentScaleFactor: ctx.tileContentScale)
        return OverlayLibrary.tileCandidateFileURLs(pyramidRoot: ctx.pyramidRoot, path: path)
            .contains { OverlayLibrary.isReadableTileFile(at: $0) }
    }
}

/// Shared tile-index math for scheduler (**internal** to avoid widening **`OverlayTilePyramidBuilder`** API).
enum OverlayTilePyramidIntersectingBounds {
    static func bounds(
        mapBoundingRect bbox: MKMapRect,
        z: Int,
        geometryFlipped: Bool,
        padTiles: Int
    ) -> (x0: Int, x1: Int, y0: Int, y1: Int)? {
        guard z >= 0, z <= 31 else { return nil }
        let world = MKMapRect.world
        let n = Double(1 << z)
        guard n.isFinite, n > 0 else { return nil }
        let tileW = world.size.width / n
        let tileH = world.size.height / n

        let x0 = Int(floor((bbox.origin.x - world.origin.x) / tileW))
        let x1 = Int(floor((bbox.maxX - world.origin.x) / tileW))

        let y0: Int
        let y1: Int
        if geometryFlipped {
            let bottomEdge = world.origin.y + world.size.height - bbox.maxY
            let topEdge = world.origin.y + world.size.height - bbox.origin.y
            y0 = Int(floor(bottomEdge / tileH))
            y1 = Int(floor(topEdge / tileH))
        } else {
            y0 = Int(floor((bbox.origin.y - world.origin.y) / tileH))
            y1 = Int(floor((bbox.maxY - world.origin.y) / tileH))
        }

        let hi = (1 << z) - 1
        func clampRange(_ a: Int, _ b: Int) -> (Int, Int) {
            let loIdx = min(a, b)
            let hiIdx = max(a, b)
            return (min(max(loIdx, 0), hi), min(max(hiIdx, 0), hi))
        }
        let (cx0, cx1) = clampRange(x0, x1)
        let (cy0, cy1) = clampRange(y0, y1)
        guard cx0 <= cx1, cy0 <= cy1 else { return nil }
        let pad = max(0, padTiles)
        return (
            max(0, cx0 - pad),
            min(hi, cx1 + pad),
            max(0, cy0 - pad),
            min(hi, cy1 + pad)
        )
    }
}

extension OverlayTileRuntimeScheduler {
    /// Builds runtime context from persisted overlay row + on-disk pyramid metadata.
    static func makeContext(
        overlayID: UUID,
        revision: Int64,
        corners: [CLLocationCoordinate2D],
        sourceRaster: Data,
        bakedFallback: UIImage,
        geometryFlipped: Bool = false,
        tileContentScale: CGFloat
    ) -> OverlayContext? {
        guard corners.count == 4 else { return nil }
        let root = OverlayLibrary.tilePyramidRevisionDirectoryURL(id: overlayID, revision: revision)
        guard FileManager.default.fileExists(atPath: root.path) else { return nil }
        let meta = OverlayLibrary.readTilePyramidMetadata(pyramidRoot: root)
        let intrinsic = OverlayMapBake.intrinsicPixelSize(from: sourceRaster) ?? (width: 1, height: 1)
        let bbox = OverlayMapBake.mapBoundingMapRect(for: corners)
        let scale = OverlayLibrary.normalizedTileContentScale(tileContentScale)
        let minZ = meta?.minZ ?? OverlayTilePyramidBuilder.highestSingleTileZoomLevel(
            mapBoundingRect: bbox,
            geometryFlipped: geometryFlipped,
            through: 22
        )
        let maxZ = meta?.maxZ ?? OverlayMapBake.nativeOverresolveMaxZoomLevel(
            intrinsicPixelWidth: intrinsic.width,
            intrinsicPixelHeight: intrinsic.height,
            mapBoundingRect: bbox,
            tileSizePoints: OverlayLibrary.logicalTileSizePoints,
            screenScale: scale
        )
        return OverlayContext(
            overlayID: overlayID,
            revision: revision,
            pyramidRoot: root,
            corners: corners,
            bbox: bbox,
            sourceRaster: sourceRaster,
            bakedFallback: bakedFallback,
            minZ: minZ,
            maxZ: maxZ,
            tileContentScale: scale,
            geometryFlipped: geometryFlipped,
            config: meta?.progressiveConfig ?? .default,
            sourceWidth: meta?.sourceWidth ?? intrinsic.width,
            sourceHeight: meta?.sourceHeight ?? intrinsic.height
        )
    }

    func startProgressiveRuntime(
        overlayID: UUID,
        revision: Int64,
        corners: [CLLocationCoordinate2D],
        sourceRaster: Data,
        bakedFallback: UIImage,
        tileContentScale: CGFloat,
        visibleMapRect: MKMapRect?,
        currentZoom: Double,
        enablePrewarm: Bool = false,
        saveTransitionRecovery: Bool = false
    ) {
        guard let ctx = Self.makeContext(
            overlayID: overlayID,
            revision: revision,
            corners: corners,
            sourceRaster: sourceRaster,
            bakedFallback: bakedFallback,
            tileContentScale: tileContentScale
        ) else { return }
        queue.async { [weak self] in
            guard let self else { return }
            if enablePrewarm {
                self.prewarmEnabledByOverlay[overlayID] = true
                if saveTransitionRecovery {
                    self.saveTransitionPrewarmRecovery[overlayID] = .outputOnly
                    print("[TileProg] saveTransition.prewarmPhase outputOnly id=\(overlayID.uuidString.prefix(8))")
                }
            }
            self.contexts[overlayID] = ctx
            print("[TileProg] register id=\(overlayID.uuidString.prefix(8)) minZ=\(ctx.minZ) maxZ=\(ctx.maxZ) rev=\(revision) prewarm=\(enablePrewarm) recovery=\(saveTransitionRecovery)")
            if let visibleMapRect {
                self.viewportEpoch &+= 1
                let snap = ViewportSnapshot(
                    visibleMapRect: visibleMapRect,
                    currentZoom: currentZoom,
                    epoch: self.viewportEpoch
                )
                self.viewports[overlayID] = snap
                if self.isPrewarmEnabled(for: overlayID) {
                    self.schedulePrewarmJobs(overlayID: overlayID, viewport: snap)
                } else {
                    print("[TileProg] viewport.prewarmSkipped id=\(overlayID.uuidString.prefix(8)) saveTransition")
                }
                self.drainQueueIfNeeded()
            }
            if enablePrewarm {
                print("[TileProg] saveTransition.prewarmEnabled id=\(overlayID.uuidString.prefix(8))")
            }
        }
    }
}
