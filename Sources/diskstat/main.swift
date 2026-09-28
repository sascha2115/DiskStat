import AppKit

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
    private var diskutilCache: [String: (fileSystem: String, partitionMap: String, timestamp: Date)] = [:]
    private let diskutilCacheTTL: TimeInterval = 60 * 5

    func allMountedDisks() -> [DiskUsage] {
        guard let urls = fileManager.mountedVolumeURLs(
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
        ) else {
            return []
        }

        let disks: [DiskUsage] = urls.compactMap { url in
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

            let meta = diskMeta(forMountPath: url.path)

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

        return disks.sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
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

        let meta = diskMeta(forMountPath: url.path)

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

    private func diskMeta(forMountPath mountPath: String) -> (fileSystem: String, partitionMap: String) {
        let now = Date()
        if let cached = diskutilCache[mountPath], now.timeIntervalSince(cached.timestamp) < diskutilCacheTTL {
            return (cached.fileSystem, cached.partitionMap)
        }

        let meta = queryDiskutilMeta(forMountPath: mountPath) ?? ("Unknown", "Unknown")
        diskutilCache[mountPath] = (meta.0, meta.1, now)
        return meta
    }

    private func queryDiskutilMeta(forMountPath mountPath: String) -> (String, String)? {
        guard let dict = diskutilInfoPlist(about: mountPath) else { return nil }

        let fs = (dict["FilesystemUserVisibleName"] as? String)
            ?? (dict["FilesystemName"] as? String)
            ?? (dict["FileSystemName"] as? String)
            ?? (dict["FileSystemPersonality"] as? String)
            ?? (dict["FilesystemType"] as? String)

        let partitionMap = resolvePartitionMap(fromDiskutilInfo: dict)

        let fsValue = (fs?.isEmpty == false) ? fs! : "Unknown"
        let mapValue = (partitionMap?.isEmpty == false) ? partitionMap! : "Unknown"
        return (fsValue, mapValue)
    }

    private func resolvePartitionMap(fromDiskutilInfo dict: [String: Any]) -> String? {
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
           let storeInfo = diskutilInfoPlist(about: storeId) {
            if let whole = (storeInfo["ParentWholeDisk"] as? String) ?? (storeInfo["DeviceIdentifier"] as? String),
               let wholeInfo = diskutilInfoPlist(about: whole),
               let content = wholeInfo["Content"] as? String {
                return normalizePartitionMap(raw: content)
            }

            if let content = storeInfo["Content"] as? String {
                return normalizePartitionMap(raw: content)
            }
        }

        if let parentWhole = dict["ParentWholeDisk"] as? String,
           let wholeInfo = diskutilInfoPlist(about: parentWhole),
           let content = wholeInfo["Content"] as? String {
            return normalizePartitionMap(raw: content)
        }

        if let content = dict["Content"] as? String {
            return normalizePartitionMap(raw: content)
        }

        return nil
    }

    private func normalizePartitionMap(raw: String) -> String? {
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

    private func diskutilInfoPlist(about target: String) -> [String: Any]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["info", "-plist", target]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard
            let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
            let dict = plist as? [String: Any]
        else {
            return nil
        }

        return dict
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

        refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.updateStatusItem()
            self?.rebuildMenu()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
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
        rebuildMenu()
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.updateStatusItem()
            self?.rebuildMenu()
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
