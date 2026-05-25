import CoreGraphics
import CoreImage
import CoreLocation
import Foundation
import ImageIO
import MapKit
import Metal
import MetalKit
import simd

/// GPU tile renderer: inverse-maps each output pixel into global source space, samples chunked source textures via **`renderWarpedTileChunk`**, then ImageIO HEIF export.
enum OverlayMetalTilePipeline {

    enum PipelineError: Error {
        case metalUnavailable
        case shaderLoadFailed(String)
        case sourceDecodeFailed
        case textureCreationFailed
        case commandCreationFailed
        case renderFailed
        case sourceDimensionMismatch(expected: (Int, Int), actual: (Int, Int))
    }

    /// Geometry-only debug toggles. Follow debug order: identity → mip 0 → alignment → affine → warp.
    struct GeometryDebugOptions: OptionSet {
        let rawValue: Int
        static let forceMipZero = GeometryDebugOptions(rawValue: 1 << 0)
        /// **`destToSource = identity`**: destination coordinate equals source pixel coordinate.
        static let identityDestToSource = GeometryDebugOptions(rawValue: 1 << 1)
    }

#if DEBUG
    /// Active while validating tile placement. Disable individual flags as each stage passes.
    static var geometryDebugOptions: GeometryDebugOptions = [.forceMipZero]
#else
    static var geometryDebugOptions: GeometryDebugOptions = []
#endif

    /// Default source chunk edge length in full-resolution source pixels.
    static let sourceChunkSide = 4096

    /// Per-tile debug record written to console during generation.
    struct TileRenderDiagnostics: CustomStringConvertible {
        let requestedZ: Int
        let sourceZ: Int
        let physicalTileSize: Int
        let sourcePixelsPerOutputPixel: Float
        let mipLevel: Float
        let overlappingChunkCount: Int
        let sourceFootprintBBox: CGRect
        let outputWidth: Int
        let outputHeight: Int

        var description: String {
            let bbox = sourceFootprintBBox
            return """
            [TileRenderDiag] requestedZ=\(requestedZ) sourceZ=\(sourceZ) physicalTilePx=\(physicalTileSize) \
            srcPxPerOutPx=\(String(format: "%.3f", sourcePixelsPerOutputPixel)) mip=\(String(format: "%.2f", mipLevel)) \
            chunks=\(overlappingChunkCount) footprint=(\(Int(bbox.minX)),\(Int(bbox.minY)),\(Int(bbox.width)),\(Int(bbox.height))) \
            output=\(outputWidth)x\(outputHeight)
            """
        }
    }

    /// One uploaded source region with its own mip chain.
    struct SourceChunk {
        let chunkX: Int
        let chunkY: Int
        let originInSourcePixels: SIMD2<Int>
        let sizeInPixels: SIMD2<Int>
        let texture: MTLTexture

        var sourceRect: CGRect {
            CGRect(
                x: originInSourcePixels.x,
                y: originInSourcePixels.y,
                width: sizeInPixels.x,
                height: sizeInPixels.y
            )
        }
    }

    /// Matches **`TileChunkUniforms`** in **`WarpedTileChunkKernel.metal`** (Metal constant-buffer layout).
    struct TileChunkUniforms {
        var outputSize: SIMD2<UInt32>
        var sourceSize: SIMD2<Float>
        var chunkOrigin: SIMD2<Float>
        var chunkSize: SIMD2<Float>
        var destOrigin: SIMD2<Float>
        var destStepX: SIMD2<Float>
        var destStepY: SIMD2<Float>
        var destToSourceColumn0: SIMD4<Float>
        var destToSourceColumn1: SIMD4<Float>
        var destToSourceColumn2: SIMD4<Float>
        var backgroundColor: SIMD4<Float>
        var mipLevel: Float
        var clearOutsideChunk: UInt32

        init(
            outputSize: SIMD2<UInt32>,
            sourceSize: SIMD2<Float>,
            chunkOrigin: SIMD2<Float>,
            chunkSize: SIMD2<Float>,
            destOrigin: SIMD2<Float>,
            destStepX: SIMD2<Float>,
            destStepY: SIMD2<Float>,
            destToSource: simd_float3x3,
            backgroundColor: SIMD4<Float>,
            mipLevel: Float,
            clearOutsideChunk: Bool
        ) {
            self.outputSize = outputSize
            self.sourceSize = sourceSize
            self.chunkOrigin = chunkOrigin
            self.chunkSize = chunkSize
            self.destOrigin = destOrigin
            self.destStepX = destStepX
            self.destStepY = destStepY
            self.destToSourceColumn0 = SIMD4(destToSource.columns.0, 0)
            self.destToSourceColumn1 = SIMD4(destToSource.columns.1, 0)
            self.destToSourceColumn2 = SIMD4(destToSource.columns.2, 0)
            self.backgroundColor = backgroundColor
            self.mipLevel = mipLevel
            self.clearOutsideChunk = clearOutsideChunk ? 1 : 0
        }
    }

    /// Chunked mipmapped source textures + dest→source homography for one overlay revision.
    final class ChunkedSourceSession {
        let chunks: [SourceChunk]
        let sourcePixelWidth: Int
        let sourcePixelHeight: Int
        let mercatorPixelWidth: Int
        let mercatorPixelHeight: Int
        let destToSource: simd_float3x3
        let chunkSide: Int

        fileprivate init(
            chunks: [SourceChunk],
            sourcePixelWidth: Int,
            sourcePixelHeight: Int,
            mercatorPixelWidth: Int,
            mercatorPixelHeight: Int,
            destToSource: simd_float3x3,
            chunkSide: Int
        ) {
            self.chunks = chunks
            self.sourcePixelWidth = sourcePixelWidth
            self.sourcePixelHeight = sourcePixelHeight
            self.mercatorPixelWidth = mercatorPixelWidth
            self.mercatorPixelHeight = mercatorPixelHeight
            self.destToSource = destToSource
            self.chunkSide = chunkSide
        }

        /// Chunks whose source-space rect intersects **`sourceRect`**.
        func chunksIntersecting(sourceRect: CGRect) -> [SourceChunk] {
            chunks.filter { $0.sourceRect.intersects(sourceRect) }
        }
    }

    /// Backward-compatible alias while callers migrate.
    typealias SourceSession = ChunkedSourceSession

    private static let device: MTLDevice? = MTLCreateSystemDefaultDevice()
    private static let commandQueue: MTLCommandQueue? = device?.makeCommandQueue()
    private static let pipelineState: MTLComputePipelineState? = {
        guard let device else { return nil }
        guard let library = device.makeDefaultLibrary(),
              let function = library.makeFunction(name: "renderWarpedTileChunk") else {
            return nil
        }
        return try? device.makeComputePipelineState(function: function)
    }()
    private static let encodeContext: CIContext? = {
        guard let device else { return nil }
        return CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
    }()

    private static let sessionCache: NSCache<NSString, ChunkedSourceSession> = {
        let cache = NSCache<NSString, ChunkedSourceSession>()
        cache.countLimit = 1
        cache.totalCostLimit = 512 * 1024 * 1024
        return cache
    }()

    /// Builds or reuses a chunked source texture session at **full intrinsic resolution** (no silent downscale).
    static func sourceSession(
        sourceRaster: Data,
        corners: [CLLocationCoordinate2D],
        mercatorPixelWidth: Int,
        mercatorPixelHeight: Int,
        cacheScope: String = ""
    ) throws -> ChunkedSourceSession {
        let scopePrefix = cacheScope.isEmpty ? "" : "\(cacheScope)-"
        let cacheKey = NSString(string: "\(scopePrefix)\(sessionCacheKey(data: sourceRaster, corners: corners, w: mercatorPixelWidth, h: mercatorPixelHeight))")
        if let cached = sessionCache.object(forKey: cacheKey) {
            return cached
        }
        guard let device, let commandQueue else { throw PipelineError.metalUnavailable }
        guard corners.count == 4, mercatorPixelWidth >= 1, mercatorPixelHeight >= 1 else {
            throw PipelineError.sourceDecodeFailed
        }
        return try autoreleasepool {
            let decodeStart = CFAbsoluteTimeGetCurrent()
            let (cgImage, intrinsicWidth, intrinsicHeight) = try decodeFullResolutionSourceCGImage(from: sourceRaster)
            OverlayTileBuildProfiling.record(.decode, seconds: CFAbsoluteTimeGetCurrent() - decodeStart)

            if mercatorPixelWidth != intrinsicWidth || mercatorPixelHeight != intrinsicHeight {
                print("[TileRenderDiag] mercator dims \(mercatorPixelWidth)x\(mercatorPixelHeight) != intrinsic \(intrinsicWidth)x\(intrinsicHeight); using intrinsic for geometry")
            }

            guard let destToSource = OverlayTileHomography.destToSourceMatrix(
                mercatorPixelWidth: mercatorPixelWidth,
                mercatorPixelHeight: mercatorPixelHeight,
                sourcePixelWidth: intrinsicWidth,
                sourcePixelHeight: intrinsicHeight,
                corners: corners
            ) else {
                throw PipelineError.sourceDecodeFailed
            }

            let session = try makeChunkedSourceSession(
                device: device,
                commandQueue: commandQueue,
                cgImage: cgImage,
                sourcePixelWidth: intrinsicWidth,
                sourcePixelHeight: intrinsicHeight,
                mercatorPixelWidth: mercatorPixelWidth,
                mercatorPixelHeight: mercatorPixelHeight,
                destToSource: destToSource,
                chunkSide: sourceChunkSide
            )
            let cost = session.chunks.reduce(0) { partial, chunk in
                partial + chunk.texture.width * chunk.texture.height * 4
            }
            sessionCache.setObject(session, forKey: cacheKey, cost: cost)
            residentSessionCacheEntries = 1
            print("[TileRenderDiag] chunkedSession ready intrinsic=\(intrinsicWidth)x\(intrinsicHeight) chunks=\(session.chunks.count) chunkSide=\(sourceChunkSide)")
            return session
        }
    }

#if DEBUG
    /// Uploads **`sourceRaster`** at full resolution with identity **`destToSource`** (geometry debug only).
    static func debugSourceSessionIdentity(
        sourceRaster: Data,
        cacheScope: String = "debug-identity"
    ) throws -> ChunkedSourceSession {
        guard let device, let commandQueue else { throw PipelineError.metalUnavailable }
        return try autoreleasepool {
            let (cgImage, intrinsicWidth, intrinsicHeight) = try decodeFullResolutionSourceCGImage(from: sourceRaster)
            return try makeChunkedSourceSession(
                device: device,
                commandQueue: commandQueue,
                cgImage: cgImage,
                sourcePixelWidth: intrinsicWidth,
                sourcePixelHeight: intrinsicHeight,
                mercatorPixelWidth: intrinsicWidth,
                mercatorPixelHeight: intrinsicHeight,
                destToSource: matrix_identity_float3x3,
                chunkSide: sourceChunkSide
            )
        }
    }
#endif

    private static var residentSessionCacheEntries = 0

    static func clearSessionCache() {
        sessionCache.removeAllObjects()
        residentSessionCacheEntries = 0
        OverlayTileRuntimeInstrumentation.recordSessionCacheEviction(reason: "clearSessionCache")
    }

    static func debugSessionCacheEntryCount() -> Int {
        residentSessionCacheEntries
    }

    /// Renders one map tile to HEIF bytes via chunked Metal inverse sampling + ImageIO export.
    static func mercatorTileHEIFData(
        session: ChunkedSourceSession,
        layout: OverlayMapBake.MercatorTileLayout,
        requestedZ: Int? = nil,
        sourceZ: Int? = nil,
        knownOpaque: Bool = false
    ) -> Data? {
        guard let cgImage = mercatorTileCGImage(
            session: session,
            layout: layout,
            requestedZ: requestedZ,
            sourceZ: sourceZ
        ) else { return nil }
        let encodeStart = CFAbsoluteTimeGetCurrent()
        let data = OverlayTileHEIFEncoding.encodeTileImageData(cgImage, knownOpaque: knownOpaque)
        OverlayTileBuildProfiling.record(.encode, seconds: CFAbsoluteTimeGetCurrent() - encodeStart)
        return data
    }

#if DEBUG
    /// Writes one rendered tile as PNG for geometry inspection (bypasses HEIF).
    static func debugWriteMercatorTilePNG(
        session: ChunkedSourceSession,
        layout: OverlayMapBake.MercatorTileLayout,
        to url: URL,
        requestedZ: Int? = nil,
        sourceZ: Int? = nil
    ) -> Bool {
        guard let cgImage = mercatorTileCGImage(
            session: session,
            layout: layout,
            requestedZ: requestedZ,
            sourceZ: sourceZ
        ) else { return false }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            return false
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        return CGImageDestinationFinalize(dest)
    }

    /// Identity-transform sanity check: **`destCoord == sourcePixel`**, **`mipLevel = 0`**.
    static func debugIdentityTileCGImage(
        sourceRaster: Data,
        layout: OverlayMapBake.MercatorTileLayout
    ) -> CGImage? {
        let prior = geometryDebugOptions
        geometryDebugOptions = [.forceMipZero, .identityDestToSource]
        defer { geometryDebugOptions = prior }
        guard let session = try? debugSourceSessionIdentity(sourceRaster: sourceRaster) else { return nil }
        return mercatorTileCGImage(session: session, layout: layout)
    }
#endif

    /// Renders one map tile to **`CGImage`** via chunked Metal (no HEIF).
    static func mercatorTileCGImage(
        session: ChunkedSourceSession,
        layout: OverlayMapBake.MercatorTileLayout,
        requestedZ: Int? = nil,
        sourceZ: Int? = nil
    ) -> CGImage? {
        guard let device,
              let commandQueue,
              let pipelineState,
              let encodeContext else { return nil }

        let outW = layout.outputWidth
        let outH = layout.outputHeight
        guard outW >= 1, outH >= 1 else { return nil }

        let basis = layout.destinationBasis()
        let destOrigin = basis.origin
        let destStepX = basis.stepX
        let destStepY = basis.stepY

        let sourcePixelsPerOutputPixel = max(
            max(abs(destStepX.x), abs(destStepX.y)),
            max(abs(destStepY.x), abs(destStepY.y))
        )
        let rawMip = sourcePixelsPerOutputPixel > 1 ? log2(sourcePixelsPerOutputPixel) : 0
        let maxMipAcrossChunks = session.chunks.map { max(0, $0.texture.mipmapLevelCount - 1) }.max() ?? 0
        let computedMip = Float(min(max(0, rawMip), Float(maxMipAcrossChunks)))
        let mipLevel: Float = geometryDebugOptions.contains(.forceMipZero) ? 0 : computedMip

        let destToSource: simd_float3x3
        if geometryDebugOptions.contains(.identityDestToSource) {
            destToSource = matrix_identity_float3x3
        } else {
            destToSource = session.destToSource
        }

        let footprint = estimateSourceFootprintBBox(
            outputWidth: outW,
            outputHeight: outH,
            destOrigin: destOrigin,
            destStepX: destStepX,
            destStepY: destStepY,
            destToSource: destToSource,
            sourceWidth: session.sourcePixelWidth,
            sourceHeight: session.sourcePixelHeight
        )
        let overlapping = session.chunksIntersecting(sourceRect: footprint)
        guard !overlapping.isEmpty else {
            print("[TileRenderDiag] no overlapping chunks for footprint \(footprint)")
            return nil
        }

        let physicalTileSize = max(outW, outH)
        let diag = TileRenderDiagnostics(
            requestedZ: requestedZ ?? -1,
            sourceZ: sourceZ ?? requestedZ ?? -1,
            physicalTileSize: physicalTileSize,
            sourcePixelsPerOutputPixel: sourcePixelsPerOutputPixel,
            mipLevel: mipLevel,
            overlappingChunkCount: overlapping.count,
            sourceFootprintBBox: footprint,
            outputWidth: outW,
            outputHeight: outH
        )
        print(diag)

        let outDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: outW,
            height: outH,
            mipmapped: false
        )
        outDesc.usage = [.shaderWrite, .shaderRead]
        outDesc.storageMode = .shared
        guard let outputTexture = device.makeTexture(descriptor: outDesc) else { return nil }

        let metalStart = CFAbsoluteTimeGetCurrent()
        guard renderTileViaChunks(
            commandQueue: commandQueue,
            pipelineState: pipelineState,
            chunks: overlapping,
            outputTexture: outputTexture,
            session: session,
            destOrigin: destOrigin,
            destStepX: destStepX,
            destStepY: destStepY,
            destToSource: destToSource,
            mipLevel: mipLevel,
            outputWidth: outW,
            outputHeight: outH
        ) else { return nil }
        OverlayTileBuildProfiling.record(.metal, seconds: CFAbsoluteTimeGetCurrent() - metalStart)

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let rawCIImage = CIImage(
            mtlTexture: outputTexture,
            options: [.colorSpace: colorSpace]
        ) else { return nil }
        let ciImage = rawCIImage.transformed(
            by: CGAffineTransform(translationX: 0, y: CGFloat(outH)).scaledBy(x: 1, y: -1)
        )
        let extent = CGRect(x: 0, y: 0, width: outW, height: outH)
        return encodeContext.createCGImage(ciImage, from: extent)
    }

    // MARK: - Source footprint

    /// Estimates axis-aligned source pixel bounds covered by an output tile (sample corners + edge midpoints).
    static func estimateSourceFootprintBBox(
        outputWidth: Int,
        outputHeight: Int,
        destOrigin: SIMD2<Float>,
        destStepX: SIMD2<Float>,
        destStepY: SIMD2<Float>,
        destToSource: simd_float3x3,
        sourceWidth: Int,
        sourceHeight: Int
    ) -> CGRect {
        let w = max(outputWidth - 1, 0)
        let h = max(outputHeight - 1, 0)
        let samplePoints: [SIMD2<Float>] = [
            SIMD2(0, 0),
            SIMD2(Float(w), 0),
            SIMD2(0, Float(h)),
            SIMD2(Float(w), Float(h)),
            SIMD2(Float(w) * 0.5, 0),
            SIMD2(Float(w) * 0.5, Float(h)),
            SIMD2(0, Float(h) * 0.5),
            SIMD2(Float(w), Float(h) * 0.5),
            SIMD2(Float(w) * 0.5, Float(h) * 0.5),
        ]
        var minX = Float.greatestFiniteMagnitude
        var minY = Float.greatestFiniteMagnitude
        var maxX = -Float.greatestFiniteMagnitude
        var maxY = -Float.greatestFiniteMagnitude
        for pt in samplePoints {
            let dest = destOrigin + pt.x * destStepX + pt.y * destStepY
            let src = applyHomography(destToSource, dest)
            minX = min(minX, src.x)
            minY = min(minY, src.y)
            maxX = max(maxX, src.x)
            maxY = max(maxY, src.y)
        }
        let clamped = CGRect(
            x: CGFloat(max(0, minX)),
            y: CGFloat(max(0, minY)),
            width: CGFloat(min(Float(sourceWidth), maxX) - max(0, minX)),
            height: CGFloat(min(Float(sourceHeight), maxY) - max(0, minY))
        )
        return clamped.isNull ? .zero : clamped
    }

    private static func applyHomography(_ m: simd_float3x3, _ p: SIMD2<Float>) -> SIMD2<Float> {
        let q = m * SIMD3(p.x, p.y, 1)
        guard abs(q.z) > 1e-12 else { return p }
        return SIMD2(q.x / q.z, q.y / q.z)
    }

    // MARK: - Private

    private static func makeChunkedSourceSession(
        device: MTLDevice,
        commandQueue: MTLCommandQueue,
        cgImage: CGImage,
        sourcePixelWidth: Int,
        sourcePixelHeight: Int,
        mercatorPixelWidth: Int,
        mercatorPixelHeight: Int,
        destToSource: simd_float3x3,
        chunkSide: Int
    ) throws -> ChunkedSourceSession {
        let descriptors = chunkDescriptors(
            sourceWidth: sourcePixelWidth,
            sourceHeight: sourcePixelHeight,
            chunkSide: chunkSide
        )
        var chunks: [SourceChunk] = []
        chunks.reserveCapacity(descriptors.count)
        for desc in descriptors {
            let cropRect = CGRect(
                x: desc.origin.x,
                y: desc.origin.y,
                width: desc.size.x,
                height: desc.size.y
            ).integral
            guard let cropped = cgImage.cropping(to: cropRect) else {
                throw PipelineError.textureCreationFailed
            }
            let texture = try makeMipmappedSourceTexture(
                device: device,
                commandQueue: commandQueue,
                cgImage: cropped
            )
            chunks.append(SourceChunk(
                chunkX: desc.chunkX,
                chunkY: desc.chunkY,
                originInSourcePixels: desc.origin,
                sizeInPixels: desc.size,
                texture: texture
            ))
        }
        return ChunkedSourceSession(
            chunks: chunks,
            sourcePixelWidth: sourcePixelWidth,
            sourcePixelHeight: sourcePixelHeight,
            mercatorPixelWidth: mercatorPixelWidth,
            mercatorPixelHeight: mercatorPixelHeight,
            destToSource: destToSource,
            chunkSide: chunkSide
        )
    }

    private struct ChunkDescriptor {
        let chunkX: Int
        let chunkY: Int
        let origin: SIMD2<Int>
        let size: SIMD2<Int>
    }

    private static func chunkDescriptors(
        sourceWidth: Int,
        sourceHeight: Int,
        chunkSide: Int
    ) -> [ChunkDescriptor] {
        let side = max(1, chunkSide)
        let cols = (sourceWidth + side - 1) / side
        let rows = (sourceHeight + side - 1) / side
        var out: [ChunkDescriptor] = []
        out.reserveCapacity(cols * rows)
        for cy in 0..<rows {
            for cx in 0..<cols {
                let ox = cx * side
                let oy = cy * side
                let w = min(side, sourceWidth - ox)
                let h = min(side, sourceHeight - oy)
                guard w > 0, h > 0 else { continue }
                out.append(ChunkDescriptor(
                    chunkX: cx,
                    chunkY: cy,
                    origin: SIMD2(ox, oy),
                    size: SIMD2(w, h)
                ))
            }
        }
        return out
    }

    private static func renderTileViaChunks(
        commandQueue: MTLCommandQueue,
        pipelineState: MTLComputePipelineState,
        chunks: [SourceChunk],
        outputTexture: MTLTexture,
        session: ChunkedSourceSession,
        destOrigin: SIMD2<Float>,
        destStepX: SIMD2<Float>,
        destStepY: SIMD2<Float>,
        destToSource: simd_float3x3,
        mipLevel: Float,
        outputWidth: Int,
        outputHeight: Int
    ) -> Bool {
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return false
        }

        encoder.setComputePipelineState(pipelineState)
        let w = pipelineState.threadExecutionWidth
        let h = max(1, pipelineState.maxTotalThreadsPerThreadgroup / w)
        let threadsPerThreadgroup = MTLSize(width: w, height: h, depth: 1)
        let threadsPerGrid = MTLSize(width: outputWidth, height: outputHeight, depth: 1)

        for (index, chunk) in chunks.enumerated() {
            var uniforms = TileChunkUniforms(
                outputSize: SIMD2<UInt32>(UInt32(outputWidth), UInt32(outputHeight)),
                sourceSize: SIMD2<Float>(Float(session.sourcePixelWidth), Float(session.sourcePixelHeight)),
                chunkOrigin: SIMD2<Float>(Float(chunk.originInSourcePixels.x), Float(chunk.originInSourcePixels.y)),
                chunkSize: SIMD2<Float>(Float(chunk.sizeInPixels.x), Float(chunk.sizeInPixels.y)),
                destOrigin: destOrigin,
                destStepX: destStepX,
                destStepY: destStepY,
                destToSource: destToSource,
                backgroundColor: SIMD4<Float>(0, 0, 0, 0),
                mipLevel: mipLevel,
                clearOutsideChunk: index == 0
            )
            encoder.setTexture(chunk.texture, index: 0)
            encoder.setTexture(outputTexture, index: 1)
            encoder.setBytes(&uniforms, length: MemoryLayout<TileChunkUniforms>.stride, index: 0)
            encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
        }

        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return commandBuffer.status == .completed
    }

    /// Decodes at full intrinsic resolution — never silently downscales via thumbnail max pixel size.
    private static func decodeFullResolutionSourceCGImage(
        from data: Data
    ) throws -> (CGImage, Int, Int) {
        try ImageIODecodeLimiter.synchronizing {
            guard let src = CGImageSourceCreateWithData(data as CFData, nil) else {
                throw PipelineError.sourceDecodeFailed
            }
            guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                  let wNum = props[kCGImagePropertyPixelWidth] as? NSNumber,
                  let hNum = props[kCGImagePropertyPixelHeight] as? NSNumber else {
                throw PipelineError.sourceDecodeFailed
            }
            let intrinsicW = wNum.intValue
            let intrinsicH = hNum.intValue
            guard intrinsicW >= 1, intrinsicH >= 1 else { throw PipelineError.sourceDecodeFailed }

            let opts: [CFString: Any] = [
                kCGImageSourceShouldCache: false,
                kCGImageSourceShouldAllowFloat: false,
            ]
            guard let cgImage = CGImageSourceCreateImageAtIndex(src, 0, opts as CFDictionary) else {
                throw PipelineError.sourceDecodeFailed
            }
            if cgImage.width != intrinsicW || cgImage.height != intrinsicH {
                throw PipelineError.sourceDimensionMismatch(
                    expected: (intrinsicW, intrinsicH),
                    actual: (cgImage.width, cgImage.height)
                )
            }
            return (cgImage, intrinsicW, intrinsicH)
        }
    }

    private static func makeMipmappedSourceTexture(
        device: MTLDevice,
        commandQueue: MTLCommandQueue,
        cgImage: CGImage
    ) throws -> MTLTexture {
        let loader = MTKTextureLoader(device: device)
        let baseOptions: [MTKTextureLoader.Option: Any] = [
            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
            .SRGB: false,
            .generateMipmaps: false,
        ]
        let baseTexture: MTLTexture
        do {
            baseTexture = try loader.newTexture(cgImage: cgImage, options: baseOptions)
        } catch {
            throw PipelineError.textureCreationFailed
        }

        let mipCount = mipLevelCount(width: baseTexture.width, height: baseTexture.height)
        guard mipCount > 1 else { return baseTexture }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: baseTexture.pixelFormat,
            width: baseTexture.width,
            height: baseTexture.height,
            mipmapped: true
        )
        desc.usage = [.shaderRead]
        desc.storageMode = .private
        guard let mipTexture = device.makeTexture(descriptor: desc),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else {
            throw PipelineError.textureCreationFailed
        }
        blit.copy(
            from: baseTexture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: baseTexture.width, height: baseTexture.height, depth: 1),
            to: mipTexture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.generateMipmaps(for: mipTexture)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else { throw PipelineError.textureCreationFailed }
        return mipTexture
    }

    private static func mipLevelCount(width: Int, height: Int) -> Int {
        Int(floor(log2(Double(max(width, height))))) + 1
    }

    private static func sessionCacheKey(
        data: Data,
        corners: [CLLocationCoordinate2D],
        w: Int,
        h: Int
    ) -> String {
        let head = data.prefix(8).map { String(format: "%02x", $0) }.joined()
        let tail = data.suffix(8).map { String(format: "%02x", $0) }.joined()
        let cornerKey = corners.map { "\($0.latitude),\($0.longitude)" }.joined(separator: "|")
        return "chunked-\(data.count)-\(w)x\(h)-\(head)-\(tail)-\(cornerKey)"
    }

    struct ChunkKey: Hashable {
        let chunkX: Int
        let chunkY: Int
    }

    /// Chunk indices covering **`sourceRect`** in full-resolution source pixel space.
    static func chunkKeysIntersecting(
        sourceRect: CGRect,
        sourceWidth: Int,
        sourceHeight: Int,
        chunkSide: Int = sourceChunkSide
    ) -> Set<ChunkKey> {
        let side = max(1, chunkSide)
        guard sourceWidth > 0, sourceHeight > 0, !sourceRect.isNull else { return [] }
        let rect = sourceRect.intersection(CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight))
        guard !rect.isNull, rect.width > 0, rect.height > 0 else { return [] }
        let x0 = max(0, Int(floor(rect.minX / CGFloat(side))))
        let x1 = min((sourceWidth + side - 1) / side - 1, Int(floor(rect.maxX / CGFloat(side))))
        let y0 = max(0, Int(floor(rect.minY / CGFloat(side))))
        let y1 = min((sourceHeight + side - 1) / side - 1, Int(floor(rect.maxY / CGFloat(side))))
        guard x0 <= x1, y0 <= y1 else { return [] }
        var keys = Set<ChunkKey>()
        for cy in y0...y1 {
            for cx in x0...x1 {
                keys.insert(ChunkKey(chunkX: cx, chunkY: cy))
            }
        }
        return keys
    }

    /// Persists one source chunk crop as HEIF under **`diskURL`**; returns **`false`** when already present.
    @discardableResult
    static func persistSourceChunkIfNeeded(
        sourceRaster: Data,
        chunkKey: ChunkKey,
        chunkSide: Int,
        sourceWidth: Int,
        sourceHeight: Int,
        diskURL: URL
    ) throws -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: diskURL.path) { return false }
        let side = max(1, chunkSide)
        let ox = chunkKey.chunkX * side
        let oy = chunkKey.chunkY * side
        let w = min(side, sourceWidth - ox)
        let h = min(side, sourceHeight - oy)
        guard w > 0, h > 0 else { return false }
        let written = try autoreleasepool { () -> Bool in
            let (cgImage, _, _) = try decodeFullResolutionSourceCGImage(from: sourceRaster)
            let crop = CGRect(x: ox, y: oy, width: w, height: h).integral
            guard let cropped = cgImage.cropping(to: crop) else { return false }
            guard let data = OverlayTileHEIFEncoding.encodeTileImageData(cropped, knownOpaque: true) else { return false }
            let dir = diskURL.deletingLastPathComponent()
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: diskURL, options: .atomic)
            return true
        }
        return written
    }

    /// Builds a session using only **`chunkKeys`**, loading persisted chunk HEIFs when available.
    static func partialSourceSession(
        sourceRaster: Data,
        corners: [CLLocationCoordinate2D],
        mercatorPixelWidth: Int,
        mercatorPixelHeight: Int,
        chunkKeys: Set<ChunkKey>,
        diskCacheRoot: URL?,
        chunkSide: Int = sourceChunkSide,
        cacheScope: String = ""
    ) throws -> ChunkedSourceSession {
        guard !chunkKeys.isEmpty else {
            return try sourceSession(
                sourceRaster: sourceRaster,
                corners: corners,
                mercatorPixelWidth: mercatorPixelWidth,
                mercatorPixelHeight: mercatorPixelHeight,
                cacheScope: cacheScope
            )
        }
        guard let device, let commandQueue else { throw PipelineError.metalUnavailable }
        guard corners.count == 4, mercatorPixelWidth >= 1, mercatorPixelHeight >= 1 else {
            throw PipelineError.sourceDecodeFailed
        }
        let (_, intrinsicW, intrinsicH) = try decodeFullResolutionSourceCGImage(from: sourceRaster)
        guard let destToSource = OverlayTileHomography.destToSourceMatrix(
            mercatorPixelWidth: mercatorPixelWidth,
            mercatorPixelHeight: mercatorPixelHeight,
            sourcePixelWidth: intrinsicW,
            sourcePixelHeight: intrinsicH,
            corners: corners
        ) else {
            throw PipelineError.sourceDecodeFailed
        }

        let descriptors = chunkDescriptors(sourceWidth: intrinsicW, sourceHeight: intrinsicH, chunkSide: chunkSide)
            .filter { chunkKeys.contains(ChunkKey(chunkX: $0.chunkX, chunkY: $0.chunkY)) }
        var chunks: [SourceChunk] = []
        chunks.reserveCapacity(descriptors.count)

        let allChunksOnDisk: Bool = {
            guard let diskCacheRoot else { return false }
            return descriptors.allSatisfy { desc in
                let url = OverlayLibrary.sourceChunkCacheFileURL(
                    pyramidRoot: diskCacheRoot,
                    chunkX: desc.chunkX,
                    chunkY: desc.chunkY
                )
                return OverlayLibrary.isReadableTileFile(at: url)
            }
        }()

        let fullCG: CGImage? = allChunksOnDisk ? nil : try autoreleasepool {
            try decodeFullResolutionSourceCGImage(from: sourceRaster).0
        }

        for desc in descriptors {
            let cropRect = CGRect(
                x: desc.origin.x,
                y: desc.origin.y,
                width: desc.size.x,
                height: desc.size.y
            ).integral
            let cgImage: CGImage?
            if let diskCacheRoot {
                let diskURL = OverlayLibrary.sourceChunkCacheFileURL(
                    pyramidRoot: diskCacheRoot,
                    chunkX: desc.chunkX,
                    chunkY: desc.chunkY
                )
                if OverlayLibrary.isReadableTileFile(at: diskURL),
                   let data = try? Data(contentsOf: diskURL),
                   let src = CGImageSourceCreateWithData(data as CFData, nil),
                   let fromDisk = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                    cgImage = fromDisk
                } else if let fullCG {
                    cgImage = fullCG.cropping(to: cropRect)
                } else {
                    cgImage = nil
                }
            } else if let fullCG {
                cgImage = fullCG.cropping(to: cropRect)
            } else {
                cgImage = nil
            }
            guard let cgImage else { throw PipelineError.textureCreationFailed }
            let texture = try makeMipmappedSourceTexture(device: device, commandQueue: commandQueue, cgImage: cgImage)
            chunks.append(SourceChunk(
                chunkX: desc.chunkX,
                chunkY: desc.chunkY,
                originInSourcePixels: desc.origin,
                sizeInPixels: desc.size,
                texture: texture
            ))
        }
        return ChunkedSourceSession(
            chunks: chunks,
            sourcePixelWidth: intrinsicW,
            sourcePixelHeight: intrinsicH,
            mercatorPixelWidth: mercatorPixelWidth,
            mercatorPixelHeight: mercatorPixelHeight,
            destToSource: destToSource,
            chunkSide: chunkSide
        )
    }
}

/// Four-point homography (**dest mercator pixels → source image pixels**, top-down).
enum OverlayTileHomography {

    static func destToSourceMatrix(
        mercatorPixelWidth: Int,
        mercatorPixelHeight: Int,
        sourcePixelWidth: Int,
        sourcePixelHeight: Int,
        corners: [CLLocationCoordinate2D]
    ) -> simd_float3x3? {
        guard mercatorPixelWidth >= 1, mercatorPixelHeight >= 1,
              sourcePixelWidth >= 1, sourcePixelHeight >= 1,
              corners.count == 4 else { return nil }
        guard let destPts = OverlayMapBake.mercatorDestinationPixelPointsTopDown(
            width: mercatorPixelWidth,
            height: mercatorPixelHeight,
            corners: corners
        ) else { return nil }

        let w = Float(sourcePixelWidth)
        let h = Float(sourcePixelHeight)
        let sourcePts: [SIMD2<Float>] = [
            SIMD2(0, 0),
            SIMD2(w, 0),
            SIMD2(w, h),
            SIMD2(0, h),
        ]
        let destSIMD = destPts.map { SIMD2(Float($0.x), Float($0.y)) }
        return homography(from: destSIMD, to: sourcePts)
    }

    /// Homography **`H`** with **`to ≈ H * from`** (homogeneous).
    private static func homography(from: [SIMD2<Float>], to: [SIMD2<Float>]) -> simd_float3x3? {
        guard from.count == 4, to.count == 4 else { return nil }
        var a = [Float](repeating: 0, count: 64)
        var b = [Float](repeating: 0, count: 8)

        for i in 0..<4 {
            let x = from[i].x
            let y = from[i].y
            let u = to[i].x
            let v = to[i].y
            let row0 = i * 2
            let row1 = row0 + 1
            a[row0 * 8 + 0] = x
            a[row0 * 8 + 1] = y
            a[row0 * 8 + 2] = 1
            a[row0 * 8 + 6] = -u * x
            a[row0 * 8 + 7] = -u * y
            b[row0] = u

            a[row1 * 8 + 3] = x
            a[row1 * 8 + 4] = y
            a[row1 * 8 + 5] = 1
            a[row1 * 8 + 6] = -v * x
            a[row1 * 8 + 7] = -v * y
            b[row1] = v
        }

        guard let hCoeffs = solve8x8(a: a, b: b) else { return nil }
        return simd_float3x3(rows: [
            SIMD3(hCoeffs[0], hCoeffs[1], hCoeffs[2]),
            SIMD3(hCoeffs[3], hCoeffs[4], hCoeffs[5]),
            SIMD3(hCoeffs[6], hCoeffs[7], 1),
        ])
    }

    private static func solve8x8(a: [Float], b: [Float]) -> [Float]? {
        var m = a
        var rhs = b
        let n = 8

        for col in 0..<n {
            var pivotRow = col
            var pivotAbs = abs(m[pivotRow * n + col])
            for row in (col + 1)..<n {
                let v = abs(m[row * n + col])
                if v > pivotAbs {
                    pivotAbs = v
                    pivotRow = row
                }
            }
            guard pivotAbs > 1e-12 else { return nil }
            if pivotRow != col {
                for k in 0..<n {
                    m.swapAt(pivotRow * n + k, col * n + k)
                }
                rhs.swapAt(pivotRow, col)
            }
            let pivot = m[col * n + col]
            for k in col..<n {
                m[col * n + k] /= pivot
            }
            rhs[col] /= pivot
            for row in 0..<n where row != col {
                let factor = m[row * n + col]
                if abs(factor) < 1e-20 { continue }
                for k in col..<n {
                    m[row * n + k] -= factor * m[col * n + k]
                }
                rhs[row] -= factor * rhs[col]
            }
        }
        return rhs
    }
}
