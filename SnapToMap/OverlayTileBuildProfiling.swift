import Foundation

/// Accumulates per-stage timings during offline **`MKTileOverlay`** pyramid builds. Log with **`[TileProfile]`** in the Xcode console.
enum OverlayTileBuildProfiling {
    enum Bucket: String, CaseIterable {
        case decode
        case metal
        case warp
        case encode
        case diskIO
        case other
    }

    struct Counters {
        var totalsMs: [Bucket: Double] = [:]
        var tileCount: Int = 0
        var nilTileCount: Int = 0

        mutating func add(_ bucket: Bucket, seconds: TimeInterval) {
            totalsMs[bucket, default: 0] += seconds * 1000
        }
    }

    final class Session {
        fileprivate var counters = Counters()
        let label: String

        init(label: String) {
            self.label = label
        }

        func record(_ bucket: Bucket, seconds: TimeInterval) {
            guard seconds.isFinite, seconds >= 0 else { return }
            OverlayTileBuildProfiling.lock.lock()
            counters.add(bucket, seconds: seconds)
            OverlayTileBuildProfiling.lock.unlock()
        }

        func recordTileProduced() {
            lock.lock()
            counters.tileCount += 1
            lock.unlock()
        }

        func recordTileNil() {
            lock.lock()
            counters.nilTileCount += 1
            lock.unlock()
        }

        func logSummary() {
            lock.lock()
            let c = counters
            lock.unlock()
            let totalMs = Bucket.allCases.reduce(0.0) { $0 + (c.totalsMs[$1] ?? 0) }
            guard totalMs > 0 || c.tileCount > 0 else { return }
            var parts: [String] = []
            for bucket in Bucket.allCases {
                let ms = c.totalsMs[bucket] ?? 0
                guard ms > 0 else { continue }
                let pct = totalMs > 0 ? (ms / totalMs) * 100 : 0
                parts.append("\(bucket.rawValue)=\(String(format: "%.0f", ms))ms(\(String(format: "%.0f", pct))%)")
            }
            print(
                "[TileProfile] \(label) tiles=\(c.tileCount) nil=\(c.nilTileCount) total=\(String(format: "%.0f", totalMs))ms \(parts.joined(separator: " "))"
            )
        }
    }

    fileprivate static let lock = NSLock()
    private static var current: Session?

    static var activeSession: Session? {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    @discardableResult
    static func withSession<T>(label: String, _ body: () throws -> T) rethrows -> T {
        let session = Session(label: label)
        lock.lock()
        current = session
        lock.unlock()
        defer {
            lock.lock()
            current = nil
            lock.unlock()
            session.logSummary()
        }
        return try body()
    }

    static func record(_ bucket: Bucket, seconds: TimeInterval) {
        activeSession?.record(bucket, seconds: seconds)
    }

    static func measure<T>(_ bucket: Bucket, _ work: () throws -> T) rethrows -> T {
        let start = CFAbsoluteTimeGetCurrent()
        let result = try work()
        record(bucket, seconds: CFAbsoluteTimeGetCurrent() - start)
        return result
    }
}

/// Quality ordering for monotonic tile display: exact **`z_n` > parent `z_n-1` > … > lazy > transparent.
struct TileDisplayQualityRank: Comparable, CustomStringConvertible {
    let requestedZ: Int
    let sourceZ: Int
    let tier: Tier

    enum Tier: Int, Comparable {
        case transparent = 0
        case lazy = 1
        case parentFallback = 2
        case remappedDisk = 3
        case exact = 4

        static func < (lhs: Tier, rhs: Tier) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    private var compositeRank: Int {
        max(sourceZ, 0) * 10 + tier.rawValue
    }

    static func < (lhs: TileDisplayQualityRank, rhs: TileDisplayQualityRank) -> Bool {
        if lhs.compositeRank != rhs.compositeRank { return lhs.compositeRank < rhs.compositeRank }
        return lhs.sourceZ < rhs.sourceZ
    }

    var fallbackDelta: Int { max(0, requestedZ - sourceZ) }

    var description: String {
        switch tier {
        case .exact:
            return "exact@z\(sourceZ)"
        case .remappedDisk:
            return "remapped@z\(sourceZ) reqZ=\(requestedZ)"
        case .parentFallback:
            return "parent@z\(sourceZ) delta=\(fallbackDelta)"
        case .lazy:
            return "lazy"
        case .transparent:
            return "transparent"
        }
    }

    static func exact(requestedZ: Int) -> TileDisplayQualityRank {
        TileDisplayQualityRank(requestedZ: requestedZ, sourceZ: requestedZ, tier: .exact)
    }

    static func remappedDisk(requestedZ: Int, sourceZ: Int) -> TileDisplayQualityRank {
        TileDisplayQualityRank(requestedZ: requestedZ, sourceZ: sourceZ, tier: .remappedDisk)
    }

    static func parentFallback(requestedZ: Int, parentZ: Int) -> TileDisplayQualityRank {
        TileDisplayQualityRank(requestedZ: requestedZ, sourceZ: parentZ, tier: .parentFallback)
    }

    static let lazy = TileDisplayQualityRank(requestedZ: 0, sourceZ: 0, tier: .lazy)
    static let transparent = TileDisplayQualityRank(requestedZ: 0, sourceZ: -1, tier: .transparent)
}

/// Runtime progressive pipeline counters — grep console for **`[TileRuntime]`** / **`[TileQuality]`**.
enum OverlayTileRuntimeInstrumentation {
    private static let lock = NSLock()
    private static var queueDepthSamples: Int = 0
    private static var lastHeartbeatAt: CFAbsoluteTime = 0
    private static var tileGenerationCounts: [String: Int] = [:]
    private static var sourceChunkLoadCounts: [String: Int] = [:]
    private static var overlayReloadCount = 0
    private static var tileInvalidationCount = 0
    private static var fallbackToExactCount = 0
    private static var exactToFallbackRegressions = 0
    private static var qualityRegressionPreventedCount = 0
    private static var qualityUpgradeCount = 0
    private static var sessionCacheEvictionCount = 0
    private static var memoryWarningCount = 0
    private static var memoryWarningTimestamps: [String] = []
    private static var lastServedKindByTile: [String: String] = [:]
    private static var lastDisplayedQualityByTile: [String: TileDisplayQualityRank] = [:]

    static func recordQueueSample(pending: Int, activeOutput: Int, activeChunks: Int, inFlightTiles: Int, inFlightChunks: Int) {
        lock.lock()
        queueDepthSamples += 1
        lock.unlock()
        maybeHeartbeat(pending: pending, activeOutput: activeOutput, activeChunks: activeChunks, inFlightTiles: inFlightTiles, inFlightChunks: inFlightChunks)
    }

    static func recordTileGenerationStart(overlayID: UUID, z: Int, x: Int, y: Int) {
        let key = tileKey(overlayID: overlayID, z: z, x: x, y: y)
        lock.lock()
        tileGenerationCounts[key, default: 0] += 1
        let count = tileGenerationCounts[key] ?? 0
        lock.unlock()
        if count > 1 {
            print("[TileRuntime] tileGen.repeat id=\(overlayID.uuidString.prefix(8)) z=\(z) x=\(x) y=\(y) count=\(count)")
        }
    }

    static func recordSourceChunkLoad(overlayID: UUID, chunkX: Int, chunkY: Int, fromDisk: Bool) {
        let key = "\(overlayID.uuidString.prefix(8)):\(chunkX),\(chunkY)"
        lock.lock()
        sourceChunkLoadCounts[key, default: 0] += 1
        let count = sourceChunkLoadCounts[key] ?? 0
        lock.unlock()
        if count > 2 {
            print("[TileRuntime] chunkLoad.repeat id=\(overlayID.uuidString.prefix(8)) cx=\(chunkX) cy=\(chunkY) fromDisk=\(fromDisk) count=\(count)")
        }
    }

    static func recordSessionCacheEviction(reason: String) {
        lock.lock()
        sessionCacheEvictionCount += 1
        let count = sessionCacheEvictionCount
        lock.unlock()
        print("[TileRuntime] sessionCache.evict reason=\(reason) total=\(count)")
    }

    static func recordOverlayReload(overlayID: UUID) {
        lock.lock()
        overlayReloadCount += 1
        let count = overlayReloadCount
        lock.unlock()
        print("[TileRuntime] overlay.reload id=\(overlayID.uuidString.prefix(8)) total=\(count)")
    }

    static func recordTileInvalidation(
        overlayID: UUID,
        z: Int,
        x: Int,
        y: Int,
        priorDisplayedQuality: TileDisplayQualityRank? = nil
    ) {
        lock.lock()
        tileInvalidationCount += 1
        let count = tileInvalidationCount
        lock.unlock()
        if let priorDisplayedQuality {
            print("[TileQuality] invalidate id=\(overlayID.uuidString.prefix(8)) z=\(z) x=\(x) y=\(y) displayed=\(priorDisplayedQuality) total=\(count)")
        } else {
            print("[TileRuntime] tile.invalidate id=\(overlayID.uuidString.prefix(8)) z=\(z) x=\(x) y=\(y) total=\(count)")
        }
    }

    static func recordTileQualityServe(
        overlayID: UUID,
        z: Int,
        x: Int,
        y: Int,
        scale100: Int,
        displayedQuality: TileDisplayQualityRank,
        replacementSource: String,
        replacementReason: String,
        proposedQuality: TileDisplayQualityRank?
    ) {
        let key = tileKey(overlayID: overlayID, z: z, x: x, y: y)
        lock.lock()
        let priorQuality = lastDisplayedQualityByTile[key]
        lastDisplayedQualityByTile[key] = displayedQuality
        lock.unlock()

        print(
            "[TileQuality] displayed id=\(overlayID.uuidString.prefix(8)) z=\(z) x=\(x) y=\(y) scale=\(String(format: "%.2f", CGFloat(scale100) / 100)) quality=\(displayedQuality) source=\(replacementSource) reason=\(replacementReason)"
        )

        if let priorQuality, displayedQuality > priorQuality,
           (displayedQuality.sourceZ > priorQuality.sourceZ
            || displayedQuality.tier.rawValue > priorQuality.tier.rawValue) {
            lock.lock()
            qualityUpgradeCount += 1
            lock.unlock()
            print("[TileQuality] upgrade id=\(overlayID.uuidString.prefix(8)) z=\(z) x=\(x) y=\(y) from=\(priorQuality) to=\(displayedQuality) reason=\(replacementReason)")
        }

        if let proposedQuality, let priorQuality, proposedQuality < priorQuality {
            lock.lock()
            qualityRegressionPreventedCount += 1
            let prevented = qualityRegressionPreventedCount
            lock.unlock()
            print(
                "[TileQuality] regressionPrevented id=\(overlayID.uuidString.prefix(8)) z=\(z) x=\(x) y=\(y) displayed=\(priorQuality) proposed=\(proposedQuality) proposedSource=\(replacementSource) fallbackDelta=\(proposedQuality.fallbackDelta) total=\(prevented)"
            )
        }

        if let priorQuality,
           (priorQuality.tier == .exact || priorQuality.tier == .remappedDisk),
           displayedQuality.tier == .parentFallback || displayedQuality.tier == .lazy {
            lock.lock()
            exactToFallbackRegressions += 1
            let regressions = exactToFallbackRegressions
            lock.unlock()
            print(
                "[TileQuality] exactToFallbackRegression id=\(overlayID.uuidString.prefix(8)) z=\(z) x=\(x) y=\(y) from=\(priorQuality) to=\(displayedQuality) source=\(replacementSource) fallbackDelta=\(displayedQuality.fallbackDelta) total=\(regressions)"
            )
        }

        recordTileServed(overlayID: overlayID, z: z, x: x, y: y, kind: replacementSource)
    }

    static func recordDisplayCacheEviction(overlayID: UUID, tileLabel: String, quality: TileDisplayQualityRank) {
        print("[TileQuality] displayCache.evict id=\(overlayID.uuidString.prefix(8)) tile=\(tileLabel) quality=\(quality)")
    }

    static func recordChunkEvictionAffectingTile(
        overlayID: UUID,
        z: Int,
        x: Int,
        y: Int,
        reason: String
    ) {
        print("[TileQuality] chunkEviction.affectsTile id=\(overlayID.uuidString.prefix(8)) z=\(z) x=\(x) y=\(y) reason=\(reason)")
    }

    static func recordMemoryWarning() {
        lock.lock()
        memoryWarningCount += 1
        let stamp = ISO8601DateFormatter().string(from: Date())
        memoryWarningTimestamps.append(stamp)
        let count = memoryWarningCount
        lock.unlock()
        print("[TileRuntime] memoryWarning total=\(count) at=\(stamp)")
    }

    static func recordTileServed(overlayID: UUID, z: Int, x: Int, y: Int, kind: String) {
        let key = tileKey(overlayID: overlayID, z: z, x: x, y: y)
        lock.lock()
        let prior = lastServedKindByTile[key]
        lastServedKindByTile[key] = kind
        lock.unlock()
        guard let prior, prior != kind else { return }
        if prior.contains("fallback") || prior.contains("parent") || prior.contains("lazy") || prior.contains("miss") {
            if kind.contains("exact") || kind.contains("diskRead") || kind.contains("memCacheHit") {
                lock.lock()
                fallbackToExactCount += 1
                lock.unlock()
                print("[TileRuntime] serve.fallbackToExact id=\(overlayID.uuidString.prefix(8)) z=\(z) x=\(x) y=\(y) from=\(prior) to=\(kind)")
            }
        }
        if (prior.contains("exact") || prior.contains("diskRead")) &&
            (kind.contains("fallback") || kind.contains("parent") || kind.contains("lazy")) {
            lock.lock()
            exactToFallbackRegressions += 1
            let regressions = exactToFallbackRegressions
            lock.unlock()
            print("[TileRuntime] serve.exactToFallback id=\(overlayID.uuidString.prefix(8)) z=\(z) x=\(x) y=\(y) from=\(prior) to=\(kind) total=\(regressions)")
        }
    }

    static func recordQueueDrain(overlayID: UUID, pending: Int, inFlightTiles: Int, inFlightChunks: Int) {
        print("[TileRuntime] queue.drain id=\(overlayID.uuidString.prefix(8)) pending=\(pending) inFlightTiles=\(inFlightTiles) inFlightChunks=\(inFlightChunks)")
    }

    private static func maybeHeartbeat(pending: Int, activeOutput: Int, activeChunks: Int, inFlightTiles: Int, inFlightChunks: Int) {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        let shouldLog = now - lastHeartbeatAt >= 2.0
        if shouldLog { lastHeartbeatAt = now }
        let reloads = overlayReloadCount
        let invalidations = tileInvalidationCount
        let regressions = exactToFallbackRegressions
        let prevented = qualityRegressionPreventedCount
        let upgrades = qualityUpgradeCount
        let memWarnings = memoryWarningCount
        let evictions = sessionCacheEvictionCount
        lock.unlock()
        guard shouldLog else { return }
        print("[TileRuntime] heartbeat pending=\(pending) activeOut=\(activeOutput) activeChunk=\(activeChunks) inFlightTiles=\(inFlightTiles) inFlightChunks=\(inFlightChunks) reloads=\(reloads) invalidations=\(invalidations) regressions=\(regressions) prevented=\(prevented) upgrades=\(upgrades) memWarnings=\(memWarnings) sessionEvictions=\(evictions)")
    }

    private static func tileKey(overlayID: UUID, z: Int, x: Int, y: Int) -> String {
        "\(overlayID.uuidString.prefix(8)):z\(z)/\(x)/\(y)"
    }
}

/// Save-after-edit staged transition checkpoints — grep **`[SaveTransition]`**.
enum OverlaySaveTransitionLog {
    static func stage(_ label: String, overlayID: UUID, extra: String = "") {
        let snap = OverlayTileRuntimeScheduler.shared.debugWorkloadSnapshot(for: overlayID)
        let metalSessions = OverlayMetalTilePipeline.debugSessionCacheEntryCount()
        let suffix = extra.isEmpty ? "" : " \(extra)"
        SnapMemoryInstrumentation.checkpoint(
            "[SaveTransition] \(label) id=\(overlayID.uuidString.prefix(8))\(suffix) pending=\(snap.pendingJobs) activeOut=\(snap.activeOutputJobs) activeChunk=\(snap.activeChunkJobs) inFlightTiles=\(snap.inFlightTiles) inFlightChunks=\(snap.inFlightChunks) prewarm=\(snap.prewarmEnabled) metalSessions=\(metalSessions)"
        )
    }
}
