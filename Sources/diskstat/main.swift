import AppKit
import Darwin

/// Minimal thread-safe box for values produced on a background queue.
private final class SynchronizedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}

/// Filesystem and partition scheme of a volume, as reported by `diskutil`.
struct DiskMeta: Equatable {
    let fileSystem: String
    let partitionMap: String

    static let unknown = DiskMeta(fileSystem: "Unknown", partitionMap: "Unknown")
}

struct DiskUsage: Identifiable {
    /// Stable identity: the same volume always produces the same id.
    ///
    /// This was a fresh `UUID()` per instance, so every refresh handed out new
    /// ids for the same disks. Nothing here reads it today — the rows are
    /// `NSView`s in an `NSMenu`, which has no notion of identity — but a
    /// changing id is the worst kind of `Identifiable`: it makes every row look
    /// new to any diffing consumer, so a future list would tear down and
    /// rebuild instead of updating, and animations and selection would not
    /// survive a refresh.
    var id: String { path }

    let name: String
    let mountURL: URL
    let totalBytes: Int64
    let freeBytes: Int64
    let isExternal: Bool
    let isEjectable: Bool
    let fileSystem: String
    let partitionMap: String

    var path: String {
        mountURL.path
    }

    var usedBytes: Int64 {
        max(0, totalBytes - freeBytes)
    }

    var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(max(Double(usedBytes) / Double(totalBytes), 0), 1)
    }

    /// Ejecting is offered for removable volumes only, and never for the one
    /// macOS is running from — which matters if the Mac was booted from an
    /// external drive, where the system volume is removable but unmounting it
    /// would pull the rug out from under the running system.
    var canEject: Bool {
        mountURL.standardizedFileURL.path != "/" && (isExternal || isEjectable)
    }
}

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
            partitionMap: meta.partitionMap
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
            partitionMap: meta.partitionMap
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

/// Blocking `diskutil` plumbing.
///
/// Everything in here blocks on a subprocess, so it must only ever be invoked
/// from a background queue — never from the main thread.
enum DiskutilInspector {
    private static let executable = URL(fileURLWithPath: "/usr/sbin/diskutil")

    /// Upper bound for a single `diskutil` invocation, so a stalled or
    /// unresponsive volume can't keep the background queue busy indefinitely.
    private static let timeout: TimeInterval = 5

    static func meta(forMountPath mountPath: String) -> DiskMeta {
        guard let dict = infoPlist(about: mountPath) else { return .unknown }

        let fileSystem = (dict["FilesystemUserVisibleName"] as? String)
            ?? (dict["FilesystemName"] as? String)
            ?? (dict["FileSystemName"] as? String)
            ?? (dict["FileSystemPersonality"] as? String)
            ?? (dict["FilesystemType"] as? String)

        return DiskMeta(
            fileSystem: nonEmpty(fileSystem) ?? "Unknown",
            partitionMap: nonEmpty(resolvePartitionMap(fromDiskutilInfo: dict)) ?? "Unknown"
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static func resolvePartitionMap(fromDiskutilInfo dict: [String: Any]) -> String? {
        // For mounted APFS volumes, partition scheme isn't exposed directly; we need to walk:
        // volume -> APFSPhysicalStore -> ParentWholeDisk -> Content (e.g. GUID_partition_scheme)
        let mapCandidates = [
            dict["PartitionMapType"] as? String,
            dict["PartitionMapScheme"] as? String,
            dict["PartitionMapTypeDescription"] as? String
        ].compactMap { $0 }

        if let direct = mapCandidates.first(where: { !$0.isEmpty }) {
            return normalizePartitionMap(raw: direct)
        }

        if let apfsStores = dict["APFSPhysicalStores"] as? [[String: Any]],
           let storeId = apfsStores.first?["APFSPhysicalStore"] as? String,
           let storeInfo = infoPlist(about: storeId) {
            if let whole = (storeInfo["ParentWholeDisk"] as? String) ?? (storeInfo["DeviceIdentifier"] as? String),
               let wholeInfo = infoPlist(about: whole),
               let content = wholeInfo["Content"] as? String {
                return normalizePartitionMap(raw: content)
            }

            if let content = storeInfo["Content"] as? String {
                return normalizePartitionMap(raw: content)
            }
        }

        if let parentWhole = dict["ParentWholeDisk"] as? String,
           let wholeInfo = infoPlist(about: parentWhole),
           let content = wholeInfo["Content"] as? String {
            return normalizePartitionMap(raw: content)
        }

        if let content = dict["Content"] as? String {
            return normalizePartitionMap(raw: content)
        }

        return nil
    }

    private static func normalizePartitionMap(raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        switch value {
        case "GPT", "GUID_partition_scheme":
            return "GUID"
        case "APM", "Apple_partition_scheme":
            return "APM"
        case "FDisk_partition_scheme", "MBR":
            return "MBR"
        default:
            // If it looks like a UUID "Content" (common on APFS container/volumes), it's not a scheme.
            if UUID(uuidString: value) != nil {
                return nil
            }
            return value
        }
    }

    // MARK: - Subprocess

    private static func infoPlist(about target: String) -> [String: Any]? {
        guard let data = runDiskutil(["info", "-plist", target]),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = plist as? [String: Any] else {
            return nil
        }

        return dict
    }

    /// Runs `diskutil` and returns its stdout, or `nil` on failure or timeout.
    ///
    /// Both pipes are drained concurrently *before* waiting for the child to
    /// exit. Reading them only after `waitUntilExit()` deadlocks as soon as the
    /// child fills the 64 KB pipe buffer, and `stderr` previously was never
    /// read at all — either case would freeze the app indefinitely.
    private static func runDiskutil(_ arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return nil
        }

        let stdout = SynchronizedBox(Data())

        // Both pipes are drained concurrently, into *separate* buffers: sharing
        // one would let a slow stderr read clobber the plist we came for.
        let drains = DispatchGroup()

        drains.enter()
        DispatchQueue.global(qos: .utility).async {
            stdout.value = outPipe.fileHandleForReading.readDataToEndOfFile()
            drains.leave()
        }

        drains.enter()
        DispatchQueue.global(qos: .utility).async {
            // Discarded, but it must still be read: an unread pipe fills up and
            // blocks the child forever.
            _ = errPipe.fileHandleForReading.readDataToEndOfFile()
            drains.leave()
        }

        let exited = DispatchGroup()
        exited.enter()
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            exited.leave()
        }

        guard exited.wait(timeout: .now() + timeout) == .success else {
            terminate(process, group: exited)
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }

        // The child is gone, so every write end is closed and this returns.
        drains.wait()
        return stdout.value
    }

    private static func terminate(_ process: Process, group: DispatchGroup) {
        process.terminate()

        guard group.wait(timeout: .now() + 1) == .timedOut, process.isRunning else { return }
        Darwin.kill(process.processIdentifier, SIGKILL)
    }
}

/// A macOS-created file or folder that does not belong on a volume shared with
/// another system.
///
/// Everything here is regenerated by macOS, which is why cleaning needs no
/// preview: the worst case is a rebuilt Spotlight index and a drive that
/// tidies itself again the next time the Mac browses it.
///
/// `.Trashes` is deliberately absent. It holds files the user deleted and may
/// still want back -- that is data, not clutter.
enum MacArtifact {
    case dsStore
    case appleDouble
    case extendedAttributes
    case spotlight
    case fileSystemEvents
    case temporaryItems

    init?(name: String) {
        switch name {
        case ".DS_Store":       self = .dsStore
        case ".Spotlight-V100": self = .spotlight
        case ".fseventsd":      self = .fileSystemEvents
        case ".TemporaryItems": self = .temporaryItems
        // Sidecars sit next to media files; `@eaDir` is numbered (@eaDir1, ...).
        case _ where name.hasPrefix("._"):      self = .appleDouble
        case _ where name.hasPrefix("@eaDir"):  self = .extendedAttributes
        default:                                return nil
        }
    }

    /// Grouped-ordering for the log summary.
    static let allCases: [MacArtifact] = [
        .dsStore, .appleDouble, .extendedAttributes, .spotlight, .fileSystemEvents, .temporaryItems
    ]

    var summary: String {
        switch self {
        case .dsStore:            return ".DS_Store files"
        case .appleDouble:        return "._ AppleDouble files"
        case .extendedAttributes: return "@eaDir metadata folders"
        case .spotlight:          return "the Spotlight index"
        case .fileSystemEvents:   return "the file change journal"
        case .temporaryItems:     return "the temporary items folder"
        }
    }
}

struct CleanableItem {
    let url: URL
    let artifact: MacArtifact
}

struct CleanResult {
    var removedPaths: [String] = []
    var failedPaths: [String] = []

    /// How many of each artefact type was removed, for the summary line.
    var removedByArtifact: [MacArtifact: Int] = [:]
    var wasCancelled = false

    var removedCount: Int { removedPaths.count }
    var failedCount: Int { failedPaths.count }
}

/// Removes macOS artefacts from a single volume.
///
/// Everything here blocks on the filesystem, so it only ever runs on a
/// background queue and never touches the main thread.
enum DiskCleaner {
    /// Cleaning is restricted to removable volumes, and never the startup disk.
    static func canClean(_ disk: DiskUsage) -> Bool {
        guard disk.isExternal else { return false }
        return disk.mountURL.standardizedFileURL.path != "/"
    }

    /// Walks the volume, then deletes what it found.
    ///
    /// Scanning first and deleting afterwards is what makes cancellation
    /// possible, and it means nothing is removed until the whole tree has been
    /// read.
    ///
    /// Returns `nil` if the volume was refused. The startup-volume check lives
    /// *here* and not only at the call site on purpose: this is the function
    /// that deletes files, and it must refuse `/` even if a future caller
    /// forgets to ask `canClean` first.
    static func clean(
        volume root: URL,
        progress: @escaping (Int) -> Void,
        isCancelled: @escaping () -> Bool
    ) -> CleanResult? {
        guard root.standardizedFileURL.path != "/" else { return nil }

        var result = CleanResult()
        let found = scan(root, progress: progress, isCancelled: isCancelled)

        if isCancelled() {
            result.wasCancelled = true
            return result
        }

        for item in found {
            do {
                try FileManager.default.removeItem(at: item.url)
                result.removedPaths.append(item.url.path)
                result.removedByArtifact[item.artifact, default: 0] += 1
            } catch {
                // A file we are not allowed to remove must not stop the run.
                result.failedPaths.append("\(item.url.path) (\(error.localizedDescription))")
            }
        }

        return result
    }

    /// Whether the entry itself is a symbolic link.
    ///
    /// `URL.resourceValues` reports on the link, not on what it points at, which
    /// is exactly what is needed here.
    private static func isSymlink(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
        return values?.isSymbolicLink == true
    }

    /// Raw directory entries, including ones Foundation hides.
    ///
    /// `FileManager.contentsOfDirectory` filters out AppleDouble files: macOS
    /// flags `._*` as hidden, so the very files this feature exists to remove
    /// are invisible to it. POSIX `readdir` has no such filter, so the scan
    /// uses it directly.
    private static func directoryEntries(_ url: URL) -> [String] {
        guard let dir = opendir(url.path) else { return [] }
        defer { closedir(dir) }

        var names: [String] = []
        while let entry = readdir(dir) {
            // d_name is a fixed-size C array, so take the bytes up to the NUL.
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw -> String in
                String(decoding: raw.bindMemory(to: UInt8.self).prefix(while: { $0 != 0 }), as: UTF8.self)
            }

            if name == "." || name == ".." { continue }
            names.append(name)
        }

        return names
    }

    private static func scan(
        _ root: URL,
        progress: (Int) -> Void,
        isCancelled: () -> Bool
    ) -> [CleanableItem] {
        var found: [CleanableItem] = []

        // An explicit walk rather than FileManager.enumerator: the enumerator
        // cannot be interrupted, and a multi-terabyte volume has to be
        // cancellable. Each directory is a bounded syscall we can check between.
        var pending: [URL] = [root]

        while let directory = pending.popLast() {
            if isCancelled() { return [] }

            for name in directoryEntries(directory) {
                let url = directory.appendingPathComponent(name)

                if let artifact = MacArtifact(name: name) {
                    found.append(CleanableItem(url: url, artifact: artifact))
                    continue
                }

                // Don't descend into hidden or @-prefixed directories: no media
                // lives there, and .Spotlight-V100 in particular is enormous and
                // slow to walk. That also leaves .Trashes untouched for free.
                guard !name.hasPrefix("."), !name.hasPrefix("@") else { continue }

                // Never follow a symlink. `opendir` resolves one, so a link on
                // the volume pointing at a folder elsewhere on the Mac would
                // otherwise pull the walk -- and the deletion -- clean outside
                // the volume the user picked. Media drives accumulate exactly
                // this kind of stray link.
                if isSymlink(url) { continue }

                pending.append(url)
            }

            progress(found.count)
        }

        return found
    }

    // MARK: - Log

    /// `~/Library/Logs/DiskStat_clean.log` — the record of what was removed.
    static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiskStat_clean.log", isDirectory: false)
    }

    /// Appends a record of a clean. A big volume can list hundreds of thousands
    /// of paths, so the file is capped and restarted once it grows too large.
    static func writeLog(disk: DiskUsage, result: CleanResult) {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH:mm:ss"

        var lines = [
            "[\(stamp.string(from: Date()))] Cleaned \(disk.name) (\(disk.path))"
        ]

        var summary = "Summary: removed=\(result.removedCount), failed=\(result.failedCount)"
        if result.wasCancelled { summary += " (cancelled)" }
        lines.append(summary)

        // Grouped by type first, so the useful part of the record survives even
        // if the cap below rolls the file over on a very large clean.
        if !result.removedByArtifact.isEmpty {
            lines.append("By type:")
            for artifact in MacArtifact.allCases where result.removedByArtifact[artifact] != nil {
                lines.append("  \(result.removedByArtifact[artifact] ?? 0) x \(artifact.summary)")
            }
        }

        lines.append("Removed items:")
        lines.append(contentsOf: result.removedPaths.sorted().map { "  \($0)" })

        if !result.failedPaths.isEmpty {
            lines.append("Failed items:")
            lines.append(contentsOf: result.failedPaths.sorted().map { "  \($0)" })
        }
        lines.append("")

        appendToLog(lines.joined(separator: "\n") + "\n")
    }

    private static func appendToLog(_ text: String) {
        let url = logURL
        let manager = FileManager.default
        let data = Data(text.utf8)

        if let attributes = try? manager.attributesOfItem(atPath: url.path),
           let size = attributes[.size] as? NSNumber,
           size.int64Value > 1_000_000 {
            try? manager.removeItem(at: url)
        }

        if !manager.fileExists(atPath: url.path) {
            try? manager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }

        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}

/// Row views are only ever built and updated on the main thread.
@MainActor
final class DiskMenuRowView: NSView {
    /// The width is fixed, but the height follows the content — see
    /// `sizeToFitContent()`.
    private static let rowWidth: CGFloat = 340
    private static let horizontalInset: CGFloat = 12
    private static let verticalInset: CGFloat = 8

    private let onEject: (() -> Void)?
    private let onClean: (() -> Void)?
    private let onCancel: (() -> Void)?

    private let detailsLabel = NSTextField(labelWithString: "")
    private let percentLabel = NSTextField(labelWithString: "")
    private let stack = NSStackView()
    private var ejectButton: NSButton?
    private var cleanButton: NSButton?

    private var normalDetails = ""
    private var normalPercent = ""
    private var isBusy = false

    init(
        disk: DiskUsage,
        formatter: ByteCountFormatter,
        onEject: (() -> Void)? = nil,
        onClean: (() -> Void)? = nil,
        onCancel: (() -> Void)? = nil
    ) {
        self.onEject = onEject
        self.onClean = onClean
        self.onCancel = onCancel
        super.init(frame: NSRect(x: 0, y: 0, width: Self.rowWidth, height: 0))

        let used = formatter.string(fromByteCount: disk.usedBytes)
        let total = formatter.string(fromByteCount: disk.totalBytes)
        let percent = Int(round(disk.usedFraction * 100))

        // Don't mutate the workspace image's `size`: it is a shared, multi-rep
        // image (32 representations at 32pt), and resizing it defers the
        // representation re-resolution. Until that settles, the image view's
        // footprint is unstable and the volume name next to it shifts a few
        // points as the row appears. Pinning the view instead lets
        // `imageScaling` downscale the 32pt icon into a fixed 24pt slot.
        let iconView = NSImageView(image: NSWorkspace.shared.icon(forFile: disk.mountURL.path))
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)

        let titleLabel = NSTextField(labelWithString: disk.name)
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        // A label's default hugging priority is low, so in a `.fill` stack it
        // would absorb the slack and move when the icon resolves. Keep it at its
        // intrinsic width and let the spacer take up the difference.
        titleLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        titleLabel.textColor = .labelColor

        let topRow = NSStackView()
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.spacing = 8
        topRow.distribution = .fill
        topRow.addArrangedSubview(iconView)
        topRow.addArrangedSubview(titleLabel)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        topRow.addArrangedSubview(spacer)

        let showEjectButton = disk.canEject

        if showEjectButton {
            let eject = NSButton(title: "", target: self, action: #selector(ejectTapped))
            eject.bezelStyle = .texturedRounded
            eject.isBordered = false
            eject.image = NSImage(
                systemSymbolName: "eject.fill",
                accessibilityDescription: "Eject \(disk.name)"
            )
            eject.contentTintColor = .secondaryLabelColor
            eject.setButtonType(.momentaryPushIn)
            eject.toolTip = "Eject \(disk.name)"
            eject.setContentHuggingPriority(.required, for: .horizontal)
            eject.setContentCompressionResistancePriority(.required, for: .horizontal)
            topRow.addArrangedSubview(eject)
            ejectButton = eject
        }

        if DiskCleaner.canClean(disk) {
            let clean = NSButton(title: "", target: self, action: #selector(cleanTapped))
            clean.bezelStyle = .texturedRounded
            clean.isBordered = false
            clean.image = NSImage(
                systemSymbolName: "sparkles",
                accessibilityDescription: "Clean \(disk.name)"
            )
            clean.contentTintColor = .secondaryLabelColor
            clean.setButtonType(.momentaryPushIn)
            clean.toolTip = "Remove macOS files, then eject"
            clean.setContentHuggingPriority(.required, for: .horizontal)
            clean.setContentCompressionResistancePriority(.required, for: .horizontal)
            topRow.addArrangedSubview(clean)
            cleanButton = clean
        }

        let progress = NSProgressIndicator()
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 100
        progress.doubleValue = Double(percent)
        progress.controlSize = .regular
        progress.style = .bar

        normalDetails = "Used: \(used) of \(total)"
        normalPercent = "\(percent)% used"

        detailsLabel.stringValue = normalDetails
        detailsLabel.font = .systemFont(ofSize: 12, weight: .regular)
        detailsLabel.textColor = .secondaryLabelColor
        detailsLabel.lineBreakMode = .byTruncatingTail

        percentLabel.stringValue = normalPercent
        percentLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        percentLabel.textColor = .labelColor
        percentLabel.alignment = .right
        percentLabel.setContentHuggingPriority(.required, for: .horizontal)

        let bottomRow = NSStackView(views: [detailsLabel, percentLabel])
        bottomRow.orientation = .horizontal
        bottomRow.alignment = .centerY
        bottomRow.spacing = 8
        bottomRow.distribution = .fill

        let metaLabel = NSTextField(labelWithString: "\(disk.fileSystem) • \(disk.partitionMap)")
        metaLabel.font = .systemFont(ofSize: 11, weight: .regular)
        metaLabel.textColor = .tertiaryLabelColor
        metaLabel.lineBreakMode = .byTruncatingTail

        let stack = self.stack
        [topRow, progress, bottomRow, metaLabel].forEach { stack.addArrangedSubview($0) }
        stack.orientation = .vertical
        stack.spacing = 6
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalInset),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalInset),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Self.verticalInset),
            // Deliberately no bottom pin. The row takes the height its content
            // needs, so a larger system font or a long volume name cannot be
            // clipped by a hardcoded frame.
            topRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            bottomRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            progress.widthAnchor.constraint(equalTo: stack.widthAnchor),
            // Fixed icon slot, so the row's layout is final on the first pass.
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24)
        ])

        // The menu is assembled from these views, so the height must be right
        // before NSMenu measures the item.
        sizeToFitContent()
    }

    override func layout() {
        super.layout()
        applyContentHeight()
    }

    private func sizeToFitContent() {
        layoutSubtreeIfNeeded()
        applyContentHeight()
    }

    /// `NSMenu` takes a custom item view's height from its frame, so a fixed
    /// frame silently clips anything taller than it. Not hypothetical: the
    /// content outgrew the hardcoded 104pt by 3pt at the current font settings,
    /// and would clip more at larger ones.
    private func applyContentHeight() {
        let needed = stack.frame.height + Self.verticalInset * 2
        guard needed > 0, abs(frame.height - needed) > 0.5 else { return }
        frame.size.height = needed
    }

    required init?(coder: NSCoder) {
        nil
    }

    @objc private func ejectTapped() {
        onEject?()
    }

    @objc private func cleanTapped() {
        if isBusy {
            onCancel?()
        } else {
            onClean?()
        }
    }

    /// Replaces the status line, used to report progress and the result.
    func setStatus(_ status: String, percent: String) {
        detailsLabel.stringValue = status
        percentLabel.stringValue = percent
    }

    /// Swaps the clean button for a cancel button while a clean is running.
    func setBusy(_ busy: Bool) {
        isBusy = busy

        ejectButton?.isEnabled = !busy
        cleanButton?.isEnabled = true
        cleanButton?.image = NSImage(
            systemSymbolName: busy ? "xmark.circle" : "sparkles",
            accessibilityDescription: busy ? "Cancel" : "Clean"
        )
        cleanButton?.toolTip = busy ? "Cancel" : "Remove macOS files, then eject"

        if !busy {
            setStatus(normalDetails, percent: normalPercent)
        }
    }
}

/// The controller owns the status item and the menu, and holds the in-flight
/// state for cleaning. All of it is main-thread state, now enforced.
@MainActor
final class DiskMenuController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let provider = DiskUsageProvider()
    private let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useTB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        formatter.includesCount = true
        return formatter
    }()

    private var statusItem: NSStatusItem!
    private let menu = NSMenu()

    /// Cleaning is filesystem work, so it runs here and never on the main thread.
    private let cleanQueue = DispatchQueue(label: "com.sascha.diskstat.clean", qos: .userInitiated)
    private let cancelClean = SynchronizedBox(false)
    private var cleaningDisk: DiskUsage?

    /// Last rendered pie, keyed by the rounded percentage it represents.
    private var pieCache: (percent: Int, image: NSImage?)?
    private var refreshTimer: Timer?
    private let refreshInterval: TimeInterval = 10

    /// Whether AppKit currently has the menu open. Tracked via the
    /// `menuWillOpen`/`menuDidClose` delegate callbacks — `NSMenu` exposes no
    /// "is tracking" property.
    private var isMenuOpen = false

    /// Set when a rebuild was requested while the menu was open, and applied
    /// once it closes. See `rebuildMenuIfIdle()`.
    private var pendingMenuRebuild = false

    /// Block observers for volume mount/unmount, removed on termination.
    private var workspaceObservers: [NSObjectProtocol] = []

    /// The row views currently on screen, keyed by mount path. The menu is
    /// rebuilt from scratch on every open, so a long-running clean has to look
    /// the *current* row up rather than the one it started with — otherwise its
    /// progress would be written to a view that is no longer in the menu.
    private var rowsByPath: [String: DiskMenuRowView] = [:]

    /// Throttles clean progress updates. The scan reports once per directory,
    /// which on a large media library is tens of thousands of callbacks, almost
    /// all of which would redraw the same label on the main thread.
    private var lastProgressUpdate: Date = .distantPast
    private let progressUpdateInterval: TimeInterval = 0.25

    private func currentRow(for disk: DiskUsage) -> DiskMenuRowView? {
        rowsByPath[disk.path]
    }

    /// Puts a row into (or out of) the cleaning state. Tolerates a row that is
    /// no longer on screen, because the menu can be rebuilt mid-clean.
    private func setRowBusy(_ busy: Bool, for disk: DiskUsage) {
        guard let row = currentRow(for: disk) else { return }
        if busy { row.setStatus("Cleaning…", percent: "") }
        row.setBusy(busy)
    }

    private func reportProgress(_ found: Int, for disk: DiskUsage) {
        let now = Date()
        guard now.timeIntervalSince(lastProgressUpdate) >= progressUpdateInterval else { return }
        lastProgressUpdate = now
        currentRow(for: disk)?.setStatus("Cleaning… \(found) found", percent: "")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.menu = menu

        if let button = statusItem.button {
            // The status item is image-only by design: the pie carries the
            // reading and the percentage lives in the tooltip. An earlier
            // version set a title here; it rendered nothing but kept the
            // button's width and font doing pointless work.
            button.imagePosition = .imageLeft
            button.toolTip = "Disk usage: unavailable"
        }

        menu.delegate = self

        updateStatusItem()
        provider.refreshDiskMetadataInBackground()

        // The timer deliberately does NOT rebuild the menu: `menuNeedsUpdate`
        // already rebuilds it on every open, and doing it here would tear down
        // the menu while the user is interacting with it — for a menu that is
        // almost never open.
        //
        // Scheduled in the common modes so the 10s cadence holds even while a
        // menu is open. AppKit runs the run loop in NSEventTrackingRunLoopMode
        // during tracking, and a plain .default-mode timer simply does not fire
        // there, which froze the menu bar icon for as long as the menu stayed
        // open. Safe now precisely because of the change above: the timer only
        // touches the status item and a background cache, never the menu.
        let timer = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            // A timer on `RunLoop.main` does fire on the main thread, so this
            // hop is not strictly needed. It is here because that guarantee
            // comes from a property of *this line* rather than from the
            // callback — and `MainActor.assumeIsolated` would turn any later
            // edit that broke it into a crash in shipped code, not a bug. One
            // run-loop turn on a ten-second timer costs nothing.
            DispatchQueue.main.async { [weak self] in
                self?.updateStatusItem()
                self?.provider.refreshDiskMetadataInBackground()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer

        // A volume appearing or disappearing is the real signal that the disk
        // list is stale. Polling alone left an ejected volume listed in the
        // menu, because `unmountAndEjectDevice` returns before the unmount has
        // actually finished, so any fixed delay is a race.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            workspaceObservers.append(
                workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    // `queue: .main` already delivers on the main thread; this
                    // hop is belt and braces, so the main-actor guarantee holds
                    // even if that queue argument is ever changed. Volume
                    // notifications are rare, so the cost is irrelevant.
                    DispatchQueue.main.async { [weak self] in
                        self?.volumesDidChange()
                    }
                }
            )
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()

        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()
    }

    /// Reacts to a volume being mounted or unmounted, by us or by anyone else.
    private func volumesDidChange() {
        updateStatusItem()
        provider.refreshDiskMetadataInBackground()
        rebuildMenuIfIdle()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        // AppKit calls this just before the menu is displayed, before it starts
        // tracking, so rebuilding here is safe. This is also the only path that
        // has to stay: it is what keeps the menu current on every open.
        pendingMenuRebuild = false
        rebuildMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false

        guard pendingMenuRebuild else { return }
        pendingMenuRebuild = false
        rebuildMenu()
    }

    /// Rebuilds the menu unless AppKit currently has it open.
    ///
    /// Mutating an `NSMenu` that is open and tracking is undefined behaviour:
    /// the highlight under the cursor can vanish mid-hover, and the click that
    /// triggered the action can be swallowed. When that is the case the request
    /// is remembered here and applied in `menuDidClose` instead.
    private func rebuildMenuIfIdle() {
        guard !isMenuOpen else {
            pendingMenuRebuild = true
            return
        }

        rebuildMenu()
    }

    private func updateStatusItem() {
        guard let primary = provider.primaryDisk() else {
            statusItem.button?.image = pieImage(fractionUsed: 0)
            statusItem.button?.toolTip = "Disk usage: unavailable"
            return
        }

        let percent = Int(round(primary.usedFraction * 100))

        // Rasterising a 20x20 image every 10 seconds, 360 times an hour, is
        // wasted work whenever the rounded percentage has not moved.
        if pieCache?.percent != percent {
            pieCache = (percent, pieImage(fractionUsed: primary.usedFraction))
        }

        statusItem.button?.image = pieCache?.image
        statusItem.button?.toolTip = "\(primary.name): \(percent)% used"
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        rowsByPath.removeAll()

        let titleItem = NSMenuItem(title: "DiskStat", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)
        menu.addItem(.separator())

        let disks = provider.allMountedDisks()
        if disks.isEmpty {
            let empty = NSMenuItem(title: "No local disks found", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for disk in disks {
                let row = DiskMenuRowView(
                    disk: disk,
                    formatter: byteFormatter,
                    onEject: { [weak self] in
                        self?.ejectDisk(disk)
                    },
                    onClean: { [weak self] in
                        self?.startClean(disk)
                    },
                    onCancel: { [weak self] in
                        self?.cancelClean.value = true
                    }
                )
                let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
                item.view = row
                item.toolTip = disk.path
                menu.addItem(item)

                rowsByPath[disk.path] = row

                // A clean that is still running outlives the row it started on,
                // so a freshly built row has to pick the state back up.
                if cleaningDisk?.path == disk.path {
                    row.setStatus("Cleaning…", percent: "")
                    row.setBusy(true)
                }

                menu.addItem(.separator())
            }

            if menu.items.last?.isSeparatorItem == true {
                menu.removeItem(at: menu.items.count - 1)
            }
        }

        menu.addItem(.separator())

        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let storageSettingsItem = NSMenuItem(title: "Open Storage Settings…", action: #selector(openStorageSettings), keyEquivalent: "")
        storageSettingsItem.target = self
        menu.addItem(storageSettingsItem)

        let quitItem = NSMenuItem(title: "Quit DiskStat", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func pieImage(fractionUsed: Double) -> NSImage? {
        let size = NSSize(width: 20, height: 20)
        let image = NSImage(size: size)

        image.lockFocus()
        defer { image.unlockFocus() }

        NSGraphicsContext.current?.imageInterpolation = .high

        let rect = NSRect(origin: .zero, size: size).insetBy(dx: 1.2, dy: 1.2)

        NSColor.controlAccentColor.withAlphaComponent(0.9).setFill()
        let start: CGFloat = 90
        let end: CGFloat = start - CGFloat(360 * fractionUsed)
        let wedge = NSBezierPath()
        wedge.move(to: NSPoint(x: rect.midX, y: rect.midY))
        wedge.appendArc(
            withCenter: NSPoint(x: rect.midX, y: rect.midY),
            radius: rect.width / 2,
            startAngle: start,
            endAngle: end,
            clockwise: true
        )
        wedge.close()
        wedge.fill()

        NSColor(calibratedWhite: 0.30, alpha: 0.75).setFill()
        let remaining = NSBezierPath()
        remaining.move(to: NSPoint(x: rect.midX, y: rect.midY))
        remaining.appendArc(
            withCenter: NSPoint(x: rect.midX, y: rect.midY),
            radius: rect.width / 2,
            startAngle: end,
            endAngle: start,
            clockwise: true
        )
        remaining.close()
        remaining.fill()

        NSColor.labelColor.withAlphaComponent(0.5).setStroke()
        let border = NSBezierPath(ovalIn: rect)
        border.lineWidth = 1
        border.stroke()

        image.isTemplate = false
        return image
    }

    @objc private func refreshNow() {
        updateStatusItem()
        // Deliberately no `rebuildMenu()`: this action fires while the menu is
        // still open and tracking. The menu closes as soon as it returns, and
        // `menuNeedsUpdate` rebuilds it from fresh data on the next open.
        provider.refreshDiskMetadataInBackground()
    }

    @objc private func openStorageSettings() {
        // One URL, not a fallback chain. `NSWorkspace.open` reports whether the
        // request was *accepted*, not whether the intended pane appeared, so
        // walking a list of schemes exits on the first accepted one even when it
        // lands on the wrong screen. Two of the previous four were legacy
        // schemes that are dead on current macOS.
        let url = URL(string: "x-apple.systempreferences:com.apple.settings.Storage")

        if let url, NSWorkspace.shared.open(url) {
            return
        }

        NSSound.beep()
    }

    /// Removes macOS artefacts from a volume and then ejects it.
    ///
    /// Cleaning and ejecting are one action on purpose: macOS recreates
    /// `.DS_Store` and `._*` as soon as the Mac browses the volume, so a clean
    /// only survives if it is the last thing done before the drive leaves.
    private func startClean(_ disk: DiskUsage) {
        guard DiskCleaner.canClean(disk), cleaningDisk == nil else { return }

        cleaningDisk = disk
        cancelClean.value = false
        lastProgressUpdate = .distantPast
        setRowBusy(true, for: disk)

        // Deliberately a strong capture: the controller must outlive this so the
        // background work can always report its result back.
        cleanQueue.async { [self] in
            guard let result = DiskCleaner.clean(
                volume: disk.mountURL,
                progress: { found in
                    DispatchQueue.main.async { self.reportProgress(found, for: disk) }
                },
                isCancelled: { self.cancelClean.value }
            ) else {
                // Refused: that is the volume macOS is running from.
                DispatchQueue.main.async {
                    self.cleaningDisk = nil
                    self.setRowBusy(false, for: disk)
                }
                return
            }

            DiskCleaner.writeLog(disk: disk, result: result)

            DispatchQueue.main.async {
                self.cleaningDisk = nil
                // The row the clean started on may be long gone; update whichever
                // row is actually on screen now.
                self.setRowBusy(false, for: disk)

                if result.wasCancelled {
                    // Leave the volume mounted: the user stopped this, they did
                    // not ask for it to be taken away.
                    self.currentRow(for: disk)?
                        .setStatus("Cancelled · \(result.removedCount) removed", percent: "")
                    return
                }

                self.ejectDisk(disk)
            }
        }
    }

    private func ejectDisk(_ disk: DiskUsage) {
        // Re-checked here as well: the button is only a hint, and the clean
        // action reaches this path too.
        guard disk.canEject else { return }

        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: disk.mountURL)

            // The eject button lives inside a custom `NSMenuItem.view`, so the
            // click never becomes a menu item action and AppKit does NOT close
            // the menu for us. Without this the menu stays open, the didUnmount
            // refresh is deferred by `rebuildMenuIfIdle()` waiting for a close
            // that never comes, and the row we just ejected sits there stale
            // until the user dismisses the menu by hand.
            menu.cancelTracking()
        } catch {
            NSSound.beep()
            print("Failed to eject \(disk.path): \(error.localizedDescription)")
        }

        // The authoritative refresh is the didUnmount notification, which fires
        // when the unmount really completes. This is only a safety net in case
        // that notification is missed, and rebuildMenuIfIdle() defers if the
        // menu is somehow still open.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.volumesDidChange()
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = DiskMenuController()
app.delegate = delegate
app.run()
