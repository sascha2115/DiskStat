import AppKit
import Darwin
import Foundation

/// Volumes, the status item and the menu are all main-thread state. The
/// compiler now enforces that rather than it being a convention.
@MainActor
final class DiskUsageProvider {
    private let fileManager = FileManager.default

    /// The resource keys every volume lookup needs.
    ///
    /// This was written out three times, and one copy silently omitted
    /// `.volumeIsLocalKey` — so the status bar and the menu list were applying
    /// different rules to the same volume.
    ///
    /// Note what is *not* here: the "important usage" and "opportunistic usage"
    /// capacity keys. See `resolveFreeBytes` for why they are not used.
    private static let volumeKeys: Set<URLResourceKey> = [
        .volumeNameKey,
        .volumeTotalCapacityKey,
        .volumeAvailableCapacityKey,
        .volumeIsInternalKey,
        .volumeIsEjectableKey,
        .volumeIsLocalKey
    ]

    private let metaCache = DiskMetaCache()

    /// Background queue for `diskutil`, which is a blocking subprocess call.
    private let metaQueue = DispatchQueue(label: "com.sascha.diskstat.diskutil", qos: .utility)

    /// Mount paths with a `diskutil` lookup currently in flight.
    private var metaInFlight = Set<String>()

    func allMountedDisks() -> [DiskUsage] {
        let urls = mountedVolumeURLs()
        metaCache.retainOnly(mountPaths: Set(urls.map(\.path)))

        let disks = urls.compactMap { diskUsage(for: $0) }

        return disks.sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// Warms the `diskutil` metadata cache without blocking the caller.
    ///
    /// `diskutil` is a subprocess and can take seconds on a slow or stalled
    /// volume, so it never runs on the main thread. Results are cached and
    /// picked up the next time the menu is rebuilt.
    func refreshDiskMetadataInBackground() {
        let paths = mountedVolumeURLs().map(\.path)
        metaCache.retainOnly(mountPaths: Set(paths))

        for path in paths {
            scheduleMetaLookup(forMountPath: path)
        }
    }

    private func scheduleMetaLookup(forMountPath path: String) {
        // Already cached and still fresh, or already being looked up.
        guard metaCache.value(forMountPath: path) == nil,
              !metaInFlight.contains(path) else {
            return
        }

        metaInFlight.insert(path)

        // Neither closure captures `self`. The background work needs nothing
        // from the provider, and the completion only needs the finished
        // metadata, so the weak reference is created once, out here, rather
        // than implicitly inherited by the outer closure.
        let finish: @MainActor @Sendable (DiskMeta, TimeInterval) -> Void = { [weak self] meta, ttl in
            self?.finishLookup(meta, ttl: ttl, forMountPath: path)
        }

        metaQueue.async {
            let meta = DiskutilInspector.meta(forMountPath: path)
            let ttl = meta == .unknown ? DiskMetaCache.failureTTL : DiskMetaCache.ttl
            DispatchQueue.main.async { finish(meta, ttl) }
        }
    }

    private func finishLookup(_ meta: DiskMeta, ttl: TimeInterval, forMountPath path: String) {
        metaInFlight.remove(path)
        // A failed lookup gets a short ttl so a transient error does not leave
        // a volume labelled "Unknown" for the full five minutes.
        metaCache.store(meta, forMountPath: path, ttl: ttl)
    }

    private func mountedVolumeURLs() -> [URL] {
        fileManager.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(Self.volumeKeys),
            options: [.skipHiddenVolumes]
        ) ?? []
    }

    private func diskUsage(for url: URL) -> DiskUsage? {
        guard let values = try? url.resourceValues(forKeys: Self.volumeKeys) else {
            return nil
        }

        guard values.volumeIsLocal != false else {
            return nil
        }

        guard let total = values.volumeTotalCapacity,
              let free = resolveFreeBytes(for: url, values: values),
              total > 0 else {
            return nil
        }

        // Cache read only — never a subprocess on the main thread.
        let meta = metaCache.value(forMountPath: url.path) ?? .unknown

        return DiskUsage(
            name: values.volumeName ?? url.lastPathComponent,
            mountURL: url,
            totalBytes: Int64(total),
            freeBytes: free,
            isExternal: values.volumeIsInternal == false,
            isEjectable: values.volumeIsEjectable == true,
            fileSystem: meta.fileSystem,
            partitionMap: meta.partitionMap,
            deviceIdentifier: meta.deviceIdentifier
        )
    }

    func primaryDisk() -> DiskUsage? {
        if let root = disk(atPath: "/") {
            return root
        }

        // Fall back to the built-in disk rather than whatever sorts first. The
        // list is ordered by name, so a drive called "Backup" would otherwise be
        // shown in the menu bar as if it were the system disk.
        let disks = allMountedDisks()
        return disks.first { !$0.isExternal } ?? disks.first
    }

    private func disk(atPath path: String) -> DiskUsage? {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: Self.volumeKeys) else {
            return nil
        }

        guard values.volumeIsLocal != false else {
            return nil
        }

        guard let total = values.volumeTotalCapacity,
              let free = resolveFreeBytes(for: url, values: values),
              total > 0 else {
            return nil
        }

        let meta = metaCache.value(forMountPath: url.path) ?? .unknown

        return DiskUsage(
            name: values.volumeName ?? "Macintosh HD",
            mountURL: url,
            totalBytes: Int64(total),
            freeBytes: free,
            isExternal: values.volumeIsInternal == false,
            isEjectable: values.volumeIsEjectable == true,
            fileSystem: meta.fileSystem,
            partitionMap: meta.partitionMap,
            deviceIdentifier: meta.deviceIdentifier
        )
    }

    /// Free space on a volume, in bytes.
    ///
    /// Deliberately just `volumeAvailableCapacity` — what `statfs` reports — for
    /// every filesystem.
    ///
    /// The other two capacity keys look like they refine this ("important" and
    /// "opportunistic" usage), but they are not more precise free space: they
    /// answer a different question, namely how willing macOS is to delete
    /// purgeable data to make room. They also cannot be ranked by
    /// "most conservative first" the way the names suggest. On this machine,
    /// sampled repeatedly and stably:
    ///
    ///     plain            276.00 GB
    ///     important        284.23 GB   <- more than the total free space
    ///     opportunistic    269.47 GB
    ///
    /// "Important usage" free space exceeding the total free space is not a
    /// typo. The previous version preferred the important value on APFS, which
    /// made the app report more free space than actually exists and disagree
    /// with Disk Utility.
    ///
    /// Plain total and plain free are also a self-consistent pair: for a system
    /// volume the total is the APFS container ceiling and the free space is the
    /// container's free space, so `total - free` comes out byte-for-byte equal
    /// to what `diskutil` reports as "Capacity In Use By Volumes".
    private func resolveFreeBytes(for url: URL, values: URLResourceValues) -> Int64? {
        if let free = values.volumeAvailableCapacity {
            return Int64(free)
        }

        // Fallback for the rare volume that will not report the key.
        if let attributes = try? fileManager.attributesOfFileSystem(forPath: url.path),
           let free = attributes[.systemFreeSize] as? NSNumber {
            return free.int64Value
        }

        return nil
    }
}
