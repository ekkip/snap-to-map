import CoreGraphics
import CoreLocation
import CoreData
import Foundation
import ImageIO
import MapKit
import UIKit

extension Notification.Name {
    static let overlayTilePyramidIterationDidChange = Notification.Name("overlayTilePyramidIterationDidChange")
}

/// Generates MapKit **`MKTileOverlayPath`** PNG pyramids under **`OverlayLibrary`** storage and updates **`StoredMapOverlay`** zoom metadata.
enum OverlayTilePyramidBuilder {
    enum BuildPhase: String {
        case preview
        case refine
        case full
    }

    struct ZoomCeilings {
        let minimumZ: Int
        let previewMaximumZ: Int
        let fullMaximumZ: Int
    }

    static let debugIterationOverlayIDKey = "overlayID"
    static let debugIterationZoomLevelKey = "zoomLevel"
    static let debugIterationMaximumZoomKey = "maximumZoom"
    static let debugIterationLevelTileIndexKey = "levelTileIndex"
    static let debugIterationLevelTileTotalKey = "levelTileTotal"
    static let debugIterationElapsedSecondsKey = "elapsedSeconds"
    static let debugIterationPhaseKey = "phase"
    static let debugIterationFinishedKey = "finished"

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

    /// Builds tiles for **`revision`** (caller already bumped **`StoredMapOverlay.tilePyramidRevision`**). Writes **`tileMinimumZoom`** / **`tileMaximumZoom`** when successful.
    static func buildAndPersistRow(
        overlayID: UUID,
        revision: Int64,
        sourceRaster: Data,
        corners: [CLLocationCoordinate2D],
        bakedMercatorDisplay: UIImage,
        geometryFlipped: Bool,
        referenceScreenScale: CGFloat,
        phase: BuildPhase,
        buildMinimumZoom: Int? = nil,
        buildMaximumZoom: Int? = nil,
        advertisedAvailableMaximumZoom: Int? = nil,
        targetFullMaximumZoom: Int? = nil,
        previewMaximumZoom: Int? = nil,
        row: StoredMapOverlay,
        context: NSManagedObjectContext
    ) throws {
        guard corners.count == 4 else { return }
        let overlayTag = String(overlayID.uuidString.prefix(8))
        defer {
            postIterationNotification(
                [
                    debugIterationOverlayIDKey: overlayID.uuidString,
                    debugIterationPhaseKey: phase.rawValue,
                    debugIterationFinishedKey: true,
                ]
            )
        }
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
        let fm = FileManager.default
        if fm.fileExists(atPath: root.path) {
            try? fm.removeItem(at: root)
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try writePyramidMetadata(
            to: root,
            yIndexMode: geometryFlipped ? "legacyFlipped" : "xyzTopDown"
        )

        let intrinsic = intrinsicPixelSize(from: sourceRaster) ?? (
            width: max(1, Int((bakedMercatorDisplay.size.width * bakedMercatorDisplay.scale).rounded())),
            height: max(1, Int((bakedMercatorDisplay.size.height * bakedMercatorDisplay.scale).rounded()))
        )

        let mercatorWidth = max(1, bakedMercatorDisplay.cgImage?.width ?? intrinsic.width)
        let mercatorHeight = max(1, bakedMercatorDisplay.cgImage?.height ?? intrinsic.height)
        let bakedFallbackCG = OverlayMapBake.normalizedCGImage(from: bakedMercatorDisplay)

        let ceilings = computeZoomCeilings(
            sourceIntrinsicSize: intrinsic,
            mercatorSize: (width: mercatorWidth, height: mercatorHeight),
            mapBoundingRect: bbox,
            referenceScreenScale: referenceScreenScale
        )
        let fullMaximumZ = ceilings.fullMaximumZ
        let minimumZ: Int = buildMinimumZoom ?? ceilings.minimumZ
        let maximumZ: Int = buildMaximumZoom ?? fullMaximumZ
        guard maximumZ >= minimumZ else { return }

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
                    screenScale: referenceScreenScale
                ),
                "sourceNativeMaxZ": OverlayMapBake.nativeMaxZoomLevel(
                    intrinsicPixelWidth: intrinsic.width,
                    intrinsicPixelHeight: intrinsic.height,
                    mapBoundingRect: bbox,
                    tileSizePoints: OverlayLibrary.logicalTileSizePoints,
                    screenScale: referenceScreenScale
                ),
                "maximumZ": maximumZ,
                "referenceScale": referenceScreenScale,
                "phase": phase.rawValue,
            ]
        )
        // #endregion

        let tileSize = OverlayLibrary.logicalTileSize
        // Keep tile file scale aligned with runtime MKTileOverlay requests (typically device scale),
        // independent from the logical-detail scale used for max-Z math.
        let dominantScale = CGFloat(max(1, Int(UIScreen.main.scale.rounded())))
        let scales: [CGFloat] = [dominantScale]
        var writtenByZ: [Int: Int] = [:]
        var intersectingCellByZ: [Int: Int] = [:]
        let sourcePixelsPerMapPoint = min(
            CGFloat(intrinsic.width) / max(1, CGFloat(bbox.size.width)),
            CGFloat(intrinsic.height) / max(1, CGFloat(bbox.size.height))
        )
        let requiredTilePixels = OverlayLibrary.logicalTileSizePoints * OverlayLibrary.tileDetailReferenceScale
        for z in stride(from: maximumZ, through: minimumZ, by: -1) {
            let levelStartedAt = Date()
            let levelPadTiles = (z == maximumZ) ? 0 : 2
            postIterationNotification(
                [
                    debugIterationOverlayIDKey: overlayID.uuidString,
                    debugIterationPhaseKey: phase.rawValue,
                    debugIterationZoomLevelKey: z,
                    debugIterationMaximumZoomKey: maximumZ,
                    debugIterationElapsedSecondsKey: 0.0,
                    debugIterationFinishedKey: false,
                ]
            )
            var writtenAtZ = 0
            var attemptedAtZ = 0
            var pngNilAtZ = 0
            if let xy = intersectingTileIndexBounds(
                mapBoundingRect: bbox,
                z: z,
                geometryFlipped: geometryFlipped,
                padTiles: levelPadTiles
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
                        "padTiles": levelPadTiles,
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

                func processCell(x: Int, y: Int) throws -> (attempted: Int, written: Int, pngNil: Int) {
                    let path = MKTileOverlayPath(x: x, y: y, z: z, contentScaleFactor: 1)
                    let tileRect = BakedImageMapTileOverlay.mercatorMapRectForOfflinePyramid(path: path, geometryFlipped: geometryFlipped)
                    let clipped = bbox.intersection(tileRect)
                    guard !clipped.isNull, !clipped.isEmpty else { return (0, 0, 0) }
                    var attempted = 0
                    var written = 0
                    var pngNil = 0
                    for scale in scales {
                        attempted += 1
                        let scaledPath = MKTileOverlayPath(x: x, y: y, z: z, contentScaleFactor: scale)
                        let data = try autoreleasepool { () -> Data? in
                            if z == maximumZ {
                                return OverlayMapBake.pngMercatorTileFromSourceRaster(
                                    sourceRaster: sourceRaster,
                                    corners: corners,
                                    mercatorPixelWidth: intrinsic.width,
                                    mercatorPixelHeight: intrinsic.height,
                                    tileRect: tileRect,
                                    bbox: bbox,
                                    clipped: clipped,
                                    tileSize: tileSize,
                                    contentScale: scale,
                                    maxThumbnailDecodeSideOverride: 6144
                                ) ?? renderTileFromBakedFallback(
                                    bakedFallbackCG: bakedFallbackCG,
                                    tileRect: tileRect,
                                    bbox: bbox,
                                    clipped: clipped,
                                    tileSize: tileSize,
                                    scale: scale
                                )
                            }
                            return makeTileFromPreviousLevelOnDisk(
                                pyramidRoot: root,
                                parentPath: scaledPath,
                                scale: scale,
                                tileSize: tileSize
                            ) ?? OverlayMapBake.pngMercatorTileFromSourceRaster(
                                sourceRaster: sourceRaster,
                                corners: corners,
                                mercatorPixelWidth: intrinsic.width,
                                mercatorPixelHeight: intrinsic.height,
                                tileRect: tileRect,
                                bbox: bbox,
                                clipped: clipped,
                                tileSize: tileSize,
                                contentScale: scale
                            ) ?? renderTileFromBakedFallback(
                                bakedFallbackCG: bakedFallbackCG,
                                tileRect: tileRect,
                                bbox: bbox,
                                clipped: clipped,
                                tileSize: tileSize,
                                scale: scale
                            )
                        }
                        guard let data else {
                            pngNil += 1
                            continue
                        }
                        let url = OverlayLibrary.tileDataFileURL(pyramidRoot: root, path: scaledPath)
                        try data.write(to: url, options: .atomic)
                        TileDiagFileLog.append("[TileDiagFile] writing z=\(scaledPath.z) x=\(scaledPath.x) y=\(scaledPath.y) scale=\(scale) -> \(url.path)")
                        written += 1
                    }
                    return (attempted, written, pngNil)
                }

                if z == maximumZ, cellCoords.count > 1 {
                    let workerCount = 2
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
                                pngNilAtZ += s.pngNil
                                processedCells += 1
                                currentProcessed = processedCells
                                let shouldPostProgress = processedCells == 1 || processedCells % 8 == 0 || processedCells == cells
                                lock.unlock()
                                if shouldPostProgress {
                                    postIterationNotification(
                                        [
                                            debugIterationOverlayIDKey: overlayID.uuidString,
                                            debugIterationPhaseKey: phase.rawValue,
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
                        pngNilAtZ += s.pngNil
                        processedCells += 1
                        let shouldPostProgress = processedCells == 1 || processedCells % 8 == 0 || processedCells == cells
                        if shouldPostProgress {
                            postIterationNotification(
                                [
                                    debugIterationOverlayIDKey: overlayID.uuidString,
                                    debugIterationPhaseKey: phase.rawValue,
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
            let sourcePixelsPerTile = Double(sourcePixelsPerMapPoint) * tileMapSpan
            let detailCoverage = requiredTilePixels > 0 ? sourcePixelsPerTile / Double(requiredTilePixels) : 0
            print("[TileDiag] build.level id=\(overlayTag) rev=\(revision) z=\(z) expectedCells=\(expectedCellsLabel) writtenPNGs=\(writtenAtZ) sourcePxPerTile=\(Int(sourcePixelsPerTile.rounded())) reqPx=\(Int(requiredTilePixels.rounded())) detailCoverage=\(String(format: "%.2f", detailCoverage))")
            // #region agent log
            agentDebugLog(
                runId: "pre-fix",
                hypothesisId: "H3_tiles_dropped_during_render",
                location: "OverlayTilePyramid.swift:buildAndPersistRow.level",
                message: "level write stats",
                data: [
                    "z": z,
                    "expectedCells": intersectingCellByZ[z] ?? 0,
                    "attemptedPNGs": attemptedAtZ,
                    "writtenPNGs": writtenAtZ,
                    "pngNilCount": pngNilAtZ,
                ]
            )
            // #endregion
        }

        SnapMemoryInstrumentation.checkpoint(
            "pyramid.build.beforePersistZoomMeta id=\(overlayID.uuidString.prefix(8))… maxZ=\(maximumZ)"
        )
        let persistedMinimumZoom = row.tileMinimumZoom >= 0 ? Int(row.tileMinimumZoom) : minimumZ
        row.tileMinimumZoom = Int32(min(persistedMinimumZoom, minimumZ))
        row.tileMaximumZoom = Int32(advertisedAvailableMaximumZoom ?? maximumZ)
        row.tileMaximumZoomFull = Int32(targetFullMaximumZoom ?? fullMaximumZ)
        row.tileMaximumZoomPreview = Int32(previewMaximumZoom ?? Int(row.tileMaximumZoom))
        row.tileRefinementInProgress = row.tileMaximumZoom < row.tileMaximumZoomFull
        try context.save()
        let totalPNGs = writtenByZ.values.reduce(0, +)
        let zSummary = writtenByZ.keys.sorted(by: >).map { z in
            "z\(z):\(writtenByZ[z] ?? 0)"
        }.joined(separator: ",")
        print("[TileDiag] build.end id=\(overlayTag) rev=\(revision) minZ=\(minimumZ) maxZ=\(maximumZ) totalPNGs=\(totalPNGs)")
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
                "phase": phase.rawValue,
                "totalPNGs": totalPNGs,
                "levelSummary": zSummary,
            ]
        )
        // #endregion
    }

    static func computeZoomCeilings(
        sourceIntrinsicSize: (width: Int, height: Int),
        mercatorSize: (width: Int, height: Int),
        mapBoundingRect bbox: MKMapRect,
        referenceScreenScale: CGFloat
    ) -> ZoomCeilings {
        let mercatorNativeMaxZ = OverlayMapBake.nativeMaxZoomLevel(
            intrinsicPixelWidth: mercatorSize.width,
            intrinsicPixelHeight: mercatorSize.height,
            mapBoundingRect: bbox,
            tileSizePoints: OverlayLibrary.logicalTileSizePoints,
            screenScale: referenceScreenScale
        )
        let sourceNativeMaxZ = OverlayMapBake.nativeMaxZoomLevel(
            intrinsicPixelWidth: sourceIntrinsicSize.width,
            intrinsicPixelHeight: sourceIntrinsicSize.height,
            mapBoundingRect: bbox,
            tileSizePoints: OverlayLibrary.logicalTileSizePoints,
            screenScale: referenceScreenScale
        )
        let fullMaximumZ = max(mercatorNativeMaxZ, sourceNativeMaxZ)
        let previewMaximumZ = min(fullMaximumZ, 0 + min(4, fullMaximumZ))
        return ZoomCeilings(minimumZ: 0, previewMaximumZ: previewMaximumZ, fullMaximumZ: fullMaximumZ)
    }

    private static func mercatorCGImageForPyramid(
        sourceRaster: Data,
        bakedFallback: UIImage,
        corners: [CLLocationCoordinate2D],
        outputWidth: Int,
        outputHeight: Int
    ) throws -> CGImage {
        let pixelsOut = outputWidth * outputHeight
        let budget = 18_000_000
        SnapMemoryInstrumentation.checkpoint("pyramid.mercatorCG.decide pixelsOut=\(pixelsOut) budget=\(budget) out=\(outputWidth)x\(outputHeight)")

        func bakedMercatorCG() throws -> CGImage {
            SnapMemoryInstrumentation.checkpoint("pyramid.mercatorCG.branch=bakedFallbackTexture")
            guard let cg = OverlayMapBake.normalizedCGImage(from: bakedFallback) else {
                throw PyramidError.missingMercatorImage
            }
            return cg
        }

        guard pixelsOut <= budget else {
            return try bakedMercatorCG()
        }

        /// **`UIImage(data:)`** materializes the **full** intrinsic bitmap — lethal for **400 MP** HEIC even when mercator **output** is small.
        guard let intrinsic = intrinsicPixelSize(from: sourceRaster) else {
            SnapMemoryInstrumentation.checkpoint("pyramid.mercatorCG.skip intrinsicUnknown→baked")
            return try bakedMercatorCG()
        }
        let intrinsicPixels = Int64(intrinsic.width) * Int64(intrinsic.height)
        guard intrinsicPixels <= OverlayLibrary.largeRasterOverlayPixelThresholdExclusive else {
            SnapMemoryInstrumentation.checkpoint("pyramid.mercatorCG.skip intrinsicPx=\(intrinsicPixels)>threshold→baked")
            return try bakedMercatorCG()
        }

        guard let pts = OverlayMapBake.mercatorDestinationPixelPoints(width: outputWidth, height: outputHeight, corners: corners),
              let ui = UIImage(data: sourceRaster)
        else {
            return try bakedMercatorCG()
        }
        let pngData = try OpenCVBridge.warpSourceToMercatorPNG(
            source: ui,
            destinationPoints: pts,
            outputWidth: outputWidth,
            outputHeight: outputHeight
        )
        guard let src = CGImageSourceCreateWithData(pngData as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw PyramidError.openCVDecodeFailed
        }
        SnapMemoryInstrumentation.checkpoint("pyramid.mercatorCG.branch=opencvWarp decoded=\(cg.width)x\(cg.height)")
        return cg
    }

    private enum PyramidError: Error {
        case missingMercatorImage
        case openCVDecodeFailed
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

    private static func renderTileFromBakedFallback(
        bakedFallbackCG: CGImage?,
        tileRect: MKMapRect,
        bbox: MKMapRect,
        clipped: MKMapRect,
        tileSize: CGSize,
        scale: CGFloat
    ) -> Data? {
        guard let bakedFallbackCG else { return nil }
        return BakedImageMapTileOverlay.mercatorTilePNGDataForOfflinePyramid(
            sourceCGImage: bakedFallbackCG,
            tileRect: tileRect,
            bbox: bbox,
            clipped: clipped,
            tileSize: tileSize,
            contentScale: scale
        )
    }

    private static func makeTileFromPreviousLevelOnDisk(
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
                for childURL in OverlayLibrary.tileCandidateFileURLs(pyramidRoot: pyramidRoot, path: childPath) {
                    if let data = try? Data(contentsOf: childURL),
                       let src = CGImageSourceCreateWithData(data as CFData, nil),
                       let decoded = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                        childCG = decoded
                        break
                    }
                }
                guard let childCG else { continue }
                let destX = CGFloat(dx) * halfW
                let destY = dy == 0 ? halfH : 0
                ctx.draw(childCG, in: CGRect(x: destX, y: destY, width: halfW, height: halfH))
                drewAny = true
            }
        }
        guard drewAny, let out = ctx.makeImage() else { return nil }
        return pngData(from: out)
    }

    private static func pngData(from cgImage: CGImage) -> Data? {
        OverlayLibrary.encodeTileImageData(cgImage)
    }

    private static func writePyramidMetadata(to root: URL, yIndexMode: String) throws {
        let metaURL = root.appendingPathComponent("pyramid-meta.json", isDirectory: false)
        let payload: [String: Any] = [
            "formatVersion": 1,
            "yIndexMode": yIndexMode,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: metaURL, options: .atomic)
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
