import Foundation
import os

/// Two-tier cache (in-memory + on-disk JSON) shared by the audio-analysis
/// clients. Behavior kept intentionally narrow: no TTL, no LRU, no async
/// eviction — iOS's `Caches` directory is evictable by the system under
/// storage pressure, which is exactly the right policy for regeneratable
/// analysis blobs.
///
/// Concurrency: actor-isolated. Each client (`SpotifyAnalysisClient`,
/// `PreviewAnalysisService`) composes one instance; callers `await get(_:)`
/// / `await put(_:_:)`. Disk I/O runs on the actor thread — payloads are
/// small (50-200 KB) so the latency is inside the tolerance for the
/// one-shot-per-track call pattern that drives this.
///
/// Write semantics: atomic (write-to-temp + rename), so a crash mid-write
/// can't leave a truncated JSON that the next launch treats as a hit.
/// Read semantics: decode failures remove the offending file and return
/// nil, so a schema-drifted cache self-heals on the next network fetch.
public actor JSONDiskCache<Key: Hashable & CustomStringConvertible & Sendable, Value: Codable & Sendable> {
    private let name: String
    private let cacheDir: URL
    private var memory: [Key: Value] = [:]
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let log: Logger

    /// - Parameter name: subdirectory under `~/Library/Caches/` (also used as
    ///   the logger category and the `NSError` domain suffix).
    public init(name: String) {
        self.name = name
        let caches = FileManager.default.urls(for: .cachesDirectory,
                                              in: .userDomainMask).first!
        self.cacheDir = caches.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir,
                                                 withIntermediateDirectories: true)
        self.log = Logger(subsystem: "dev.studiojoe.Core",
                          category: "JSONDiskCache.\(name)")
    }

    /// Memory → disk (populates memory on hit) → nil.
    public func get(_ key: Key) -> Value? {
        if let hit = memory[key] { return hit }
        if let fromDisk = loadFromDisk(key) {
            memory[key] = fromDisk
            log.info("disk hit \(String(describing: key), privacy: .public)")
            return fromDisk
        }
        return nil
    }

    /// Writes to both tiers. Disk write is atomic; a failure is logged and
    /// swallowed — the value is still in memory for the current process.
    public func put(_ key: Key, _ value: Value) {
        memory[key] = value
        saveToDisk(key, value)
    }

    /// Drops the in-memory dict AND wipes the disk directory. Used by
    /// "Clear cache" affordances and tests.
    public func clear() {
        memory.removeAll()
        do {
            let files = try FileManager.default.contentsOfDirectory(
                at: cacheDir, includingPropertiesForKeys: nil)
            for f in files { try? FileManager.default.removeItem(at: f) }
            log.info("cleared (memory + \(files.count, privacy: .public) disk files)")
        } catch {
            log.warning("clear failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Disk

    private func fileURL(for key: Key) -> URL {
        cacheDir.appendingPathComponent("\(key).json")
    }

    private func loadFromDisk(_ key: Key) -> Value? {
        let url = fileURL(for: key)
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try decoder.decode(Value.self, from: data)
        } catch {
            // Corrupt or schema-drifted cache file. Remove so the next call
            // falls through to the network and writes a valid blob.
            log.warning("decode failed for \(String(describing: key), privacy: .public): \(error.localizedDescription, privacy: .public) — removing")
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    private func saveToDisk(_ key: Key, _ value: Value) {
        let url = fileURL(for: key)
        do {
            let data = try encoder.encode(value)
            try data.write(to: url, options: .atomic)
            log.info("wrote \(String(describing: key), privacy: .public) (\(data.count, privacy: .public) bytes)")
        } catch {
            log.warning("write failed for \(String(describing: key), privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
