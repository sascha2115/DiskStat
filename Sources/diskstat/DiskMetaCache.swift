import Foundation

/// Thread-safe cache for `diskutil` metadata.
///
/// Read on the main thread whenever the menu is rebuilt and written on a
/// background queue, so it never blocks and never touches the filesystem.
final class DiskMetaCache: @unchecked Sendable {
    /// How long a successful lookup stays valid.
    static let ttl: TimeInterval = 60 * 5

    /// Failed lookups are retried sooner than successful ones, so a single
    /// transient error doesn't leave a volume labelled "Unknown" for minutes.
    static let failureTTL: TimeInterval = 60

    private struct Entry {
        let meta: DiskMeta
        let timestamp: Date
        let ttl: TimeInterval
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    /// Returns the cached metadata, or `nil` when it is missing or stale.
    func value(forMountPath path: String) -> DiskMeta? {
        lock.lock()
        defer { lock.unlock() }

        guard let entry = entries[path],
              Date().timeIntervalSince(entry.timestamp) < entry.ttl else {
            return nil
        }

        return entry.meta
    }

    func store(_ meta: DiskMeta, forMountPath path: String, ttl: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }

        entries[path] = Entry(meta: meta, timestamp: Date(), ttl: ttl)
    }

    /// Drops entries for volumes that are no longer mounted.
    func retainOnly(mountPaths: Set<String>) {
        lock.lock()
        defer { lock.unlock() }

        entries = entries.filter { mountPaths.contains($0.key) }
    }
}
