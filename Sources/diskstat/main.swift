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
    let id = UUID()
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
}


final class DiskUsageProvider {
    private let fileManager = FileManager.default
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

        metaQueue.async { [weak self] in
            let meta = DiskutilInspector.meta(forMountPath: path)

            DispatchQueue.main.async {
                guard let self else { return }
                self.metaInFlight.remove(path)
                self.metaCache.store(
                    meta,
                    forMountPath: path,
                    // Don't hold on to a failure: retry sooner than a real hit.
                    ttl: meta == .unknown ? DiskMetaCache.failureTTL : DiskMetaCache.ttl
                )
            }
        }
    }

    private func mountedVolumeURLs() -> [URL] {
        fileManager.mountedVolumeURLs(
            includingResourceValuesForKeys: [
                .volumeNameKey,
                .volumeLocalizedFormatDescriptionKey,
                .volumeTotalCapacityKey,
                .volumeAvailableCapacityKey,
                .volumeAvailableCapacityForImportantUsageKey,
                .volumeAvailableCapacityForOpportunisticUsageKey,
                .volumeIsInternalKey,
                .volumeIsEjectableKey,
                .volumeIsLocalKey
            ],
            options: [.skipHiddenVolumes]
        ) ?? []
    }

    private func diskUsage(for url: URL) -> DiskUsage? {
        guard let values = try? url.resourceValues(forKeys: [
            .volumeNameKey,
            .volumeLocalizedFormatDescriptionKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityForOpportunisticUsageKey,
            .volumeIsInternalKey,
            .volumeIsEjectableKey,
            .volumeIsLocalKey
        ]) else {
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

        return allMountedDisks().first
    }

    private func disk(atPath path: String) -> DiskUsage? {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [
            .volumeNameKey,
            .volumeLocalizedFormatDescriptionKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityForOpportunisticUsageKey,
            .volumeIsInternalKey,
            .volumeIsEjectableKey
        ]),
        let total = values.volumeTotalCapacity,
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

    private func resolveFreeBytes(for url: URL, values: URLResourceValues) -> Int64? {
        let isAPFS = values.volumeLocalizedFormatDescription?
            .localizedCaseInsensitiveContains("APFS") == true

        let candidates: [Int64?]
        if isAPFS {
            candidates = [
                values.volumeAvailableCapacityForImportantUsage,
                values.volumeAvailableCapacityForOpportunisticUsage,
                values.volumeAvailableCapacity.map(Int64.init)
            ]
        } else {
            candidates = [
                values.volumeAvailableCapacity.map(Int64.init),
                values.volumeAvailableCapacityForImportantUsage,
                values.volumeAvailableCapacityForOpportunisticUsage
            ]
        }

        if let positive = candidates.compactMap({ $0 }).first(where: { $0 > 0 }) {
            return positive
        }
        if let zero = candidates.compactMap({ $0 }).first(where: { $0 == 0 }) {
            return zero
        }

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

final class DiskMenuRowView: NSView {
    private let onEject: (() -> Void)?

    init(
        disk: DiskUsage,
        formatter: ByteCountFormatter,
        onEject: (() -> Void)? = nil
    ) {
        self.onEject = onEject
        super.init(frame: NSRect(x: 0, y: 0, width: 340, height: 104))

        wantsLayer = true

        let used = formatter.string(fromByteCount: disk.usedBytes)
        let total = formatter.string(fromByteCount: disk.totalBytes)
        let percent = Int(round(disk.usedFraction * 100))

        let iconImage = NSWorkspace.shared.icon(forFile: disk.mountURL.path)
        iconImage.size = NSSize(width: 24, height: 24)
        let iconView = NSImageView(image: iconImage)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown

        let titleLabel = NSTextField(labelWithString: disk.name)
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
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

        let showEjectButton = disk.isExternal || disk.isEjectable

        if showEjectButton {
            let ejectButton = NSButton(title: "", target: self, action: #selector(ejectTapped))
            ejectButton.bezelStyle = .texturedRounded
            ejectButton.isBordered = false
            ejectButton.image = NSImage(
                systemSymbolName: "eject.fill",
                accessibilityDescription: "Eject \(disk.name)"
            )
            ejectButton.contentTintColor = .secondaryLabelColor
            ejectButton.setButtonType(.momentaryPushIn)
            ejectButton.toolTip = "Eject \(disk.name)"
            ejectButton.setContentHuggingPriority(.required, for: .horizontal)
            ejectButton.setContentCompressionResistancePriority(.required, for: .horizontal)
            topRow.addArrangedSubview(ejectButton)
        }

        let progress = NSProgressIndicator()
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 100
        progress.doubleValue = Double(percent)
        progress.controlSize = .regular
        progress.style = .bar

        let detailsLabel = NSTextField(labelWithString: "Used: \(used) of \(total)")
        detailsLabel.font = .systemFont(ofSize: 12, weight: .regular)
        detailsLabel.textColor = .secondaryLabelColor
        detailsLabel.lineBreakMode = .byTruncatingTail

        let percentLabel = NSTextField(labelWithString: "\(percent)% used")
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

        let stack = NSStackView(views: [topRow, progress, bottomRow, metaLabel])
        stack.orientation = .vertical
        stack.spacing = 6
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            topRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            bottomRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            progress.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    @objc private func ejectTapped() {
        onEject?()
    }

}

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
    private var refreshTimer: Timer?
    private let refreshInterval: TimeInterval = 10

    /// Whether AppKit currently has the menu open. Tracked via the
    /// `menuWillOpen`/`menuDidClose` delegate callbacks — `NSMenu` exposes no
    /// "is tracking" property.
    private var isMenuOpen = false

    /// Set when a rebuild was requested while the menu was open, and applied
    /// once it closes. See `rebuildMenuIfIdle()`.
    private var pendingMenuRebuild = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.menu = menu

        if let button = statusItem.button {
            button.imagePosition = .imageLeft
            button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
            button.title = ""
            button.toolTip = "Disk usage: unavailable"
        }

        menu.delegate = self

        updateStatusItem()
        provider.refreshDiskMetadataInBackground()

        // The timer deliberately does NOT rebuild the menu: `menuNeedsUpdate`
        // already rebuilds it on every open, and doing it here would tear down
        // the menu while the user is interacting with it — for a menu that is
        // almost never open.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.updateStatusItem()
            self?.provider.refreshDiskMetadataInBackground()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
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
            statusItem.button?.title = ""
            statusItem.button?.image = pieImage(fractionUsed: 0)
            statusItem.button?.toolTip = "Disk usage: unavailable"
            return
        }

        let percent = Int(round(primary.usedFraction * 100))
        statusItem.button?.title = ""
        statusItem.button?.image = pieImage(fractionUsed: primary.usedFraction)
        statusItem.button?.toolTip = "\(primary.name): \(percent)% used"
    }

    private func rebuildMenu() {
        menu.removeAllItems()

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
                let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
                item.view = DiskMenuRowView(
                    disk: disk,
                    formatter: byteFormatter,
                    onEject: { [weak self] in
                        self?.ejectDisk(disk)
                    }
                )
                item.toolTip = disk.path
                menu.addItem(item)

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
        let urls = [
            "x-apple.systempreferences:com.apple.settings.Storage",
            "x-apple.systempreferences:com.apple.settings.Storage?path=General",
            "x-apple.systempreferences:com.apple.preferences.storage",
            "x-apple.systempreferences:com.apple.preference.general?Storage"
        ].compactMap(URL.init(string:))

        for url in urls {
            if NSWorkspace.shared.open(url) {
                return
            }
        }

        NSSound.beep()
    }

    private func ejectDisk(_ disk: DiskUsage) {
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: disk.mountURL)
        } catch {
            NSSound.beep()
            print("Failed to eject \(disk.path): \(error.localizedDescription)")
        }
        // The eject button lives inside the menu, so this can land while AppKit
        // is still tracking it — rebuildMenuIfIdle() defers in that case.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.updateStatusItem()
            self?.rebuildMenuIfIdle()
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
