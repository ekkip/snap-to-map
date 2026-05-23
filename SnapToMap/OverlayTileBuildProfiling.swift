import Foundation

/// Accumulates per-stage timings during offline **`MKTileOverlay`** pyramid builds. Log with **`[TileProfile]`** in the Xcode console.
///
/// Metal per-tile kernels and VideoToolbox HEIF encoding remain **out of scope** until **`[TileProfile]`** shows warp or encode dominating total time (see migration plan).
enum OverlayTileBuildProfiling {
    enum Bucket: String, CaseIterable {
        case decode
        case warp
        case encode
        case diskIO
        case composite
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
