import AppKit
import UserNotifications

struct DiskUsage: Identifiable {
    let id = UUID()
    let name: String
    let mountURL: URL
    let totalBytes: Int64
    let freeBytes: Int64
    let isExternal: Bool
    let isEjectable: Bool

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

struct CleanupResult {
    var removedItems: [String] = []
    var failedItems: [String] = []

    var removedCount: Int { removedItems.count }
    var failedCount: Int { failedItems.count }
}

final class DiskUsageProvider {
    private let fileManager = FileManager.default

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

            return DiskUsage(
                name: values.volumeName ?? url.lastPathComponent,
                mountURL: url,
                totalBytes: Int64(total),
                freeBytes: free,
                isExternal: values.volumeIsInternal == false,
                isEjectable: values.volumeIsEjectable == true
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

        return DiskUsage(
            name: values.volumeName ?? "Macintosh HD",
            mountURL: url,
            totalBytes: Int64(total),
            freeBytes: free,
            isExternal: values.volumeIsInternal == false,
            isEjectable: values.volumeIsEjectable == true
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

final class DiskMenuRowView: NSView {
    private let onEject: (() -> Void)?
    private let onClean: (() -> Void)?

    init(
        disk: DiskUsage,
        formatter: ByteCountFormatter,
        onClean: (() -> Void)? = nil,
        onEject: (() -> Void)? = nil
    ) {
        self.onClean = onClean
        self.onEject = onEject
        super.init(frame: NSRect(x: 0, y: 0, width: 340, height: 88))

        wantsLayer = true

        let used = formatter.string(fromByteCount: disk.usedBytes)
        let total = formatter.string(fromByteCount: disk.totalBytes)
        let percent = Int(round(disk.usedFraction * 100))

        let titleLabel = NSTextField(labelWithString: disk.name)
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.textColor = .labelColor

        let topRow = NSStackView()
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.spacing = 8
        topRow.distribution = .fill
        topRow.addArrangedSubview(titleLabel)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        topRow.addArrangedSubview(spacer)

        let showEjectButton = disk.isExternal || disk.isEjectable
        if disk.isExternal {
            let cleanButton = NSButton(title: "", target: self, action: #selector(cleanTapped))
            cleanButton.bezelStyle = .texturedRounded
            cleanButton.isBordered = false
            let cleanSymbols = ["bolt.slash", "bolt.slash.fill", "trash.slash.fill", "trash.slash"]
            cleanButton.image = cleanSymbols
                .compactMap { NSImage(systemSymbolName: $0, accessibilityDescription: "Clean hidden files on \(disk.name)") }
                .first
            cleanButton.contentTintColor = .secondaryLabelColor
            cleanButton.setButtonType(.momentaryPushIn)
            cleanButton.toolTip = "Clean and Eject Disk"
            cleanButton.setContentHuggingPriority(.required, for: .horizontal)
            cleanButton.setContentCompressionResistancePriority(.required, for: .horizontal)
            topRow.addArrangedSubview(cleanButton)
        }

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

        let stack = NSStackView(views: [topRow, progress, bottomRow])
        stack.orientation = .vertical
        stack.spacing = 7
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

    @objc private func cleanTapped() {
        onClean?()
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
    private let canUseUserNotifications: Bool = {
        let bundleURL = Bundle.main.bundleURL
        return bundleURL.pathExtension.lowercased() == "app" && Bundle.main.bundleIdentifier != nil
    }()

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

        requestNotificationAuthorization()
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
                    onClean: { [weak self] in
                        self?.cleanDisk(disk)
                    },
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

    private func cleanDisk(_ disk: DiskUsage) {
        guard disk.isExternal else { return }

        let targetURL = disk.mountURL
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Self.performMacMetadataCleanup(at: targetURL)
            Self.appendCleanupLog(
                diskName: disk.name,
                diskPath: targetURL.path,
                result: result
            )
            DispatchQueue.main.async {
                self?.menu.cancelTracking()

                var ejectError: Error?
                do {
                    try NSWorkspace.shared.unmountAndEjectDevice(at: targetURL)
                } catch {
                    ejectError = error
                    NSSound.beep()
                    print("Failed to eject \(targetURL.path): \(error.localizedDescription)")
                }

                self?.postCleanupNotification(
                    diskName: disk.name,
                    result: result,
                    ejectError: ejectError
                )
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self?.updateStatusItem()
                    self?.rebuildMenu()
                }
            }
        }
    }

    private func requestNotificationAuthorization() {
        guard canUseUserNotifications else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func postCleanupNotification(
        diskName: String,
        result: CleanupResult,
        ejectError: Error?
    ) {
        guard canUseUserNotifications else { return }
        let content = UNMutableNotificationContent()
        if ejectError == nil {
            content.title = "Disk cleaned and ejected"
            content.body = "\(diskName): removed \(result.removedCount), failed \(result.failedCount)."
        } else {
            content.title = "Disk cleaned (eject failed)"
            content.body = "\(diskName): removed \(result.removedCount), failed \(result.failedCount). Eject failed."
        }
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "diskstat.cleanup.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private static func appendCleanupLog(
        diskName: String,
        diskPath: String,
        result: CleanupResult
    ) {
        let maxLogBytes = 1_000_000
        let retainLogBytes = 750_000

        let timestampFormatter = DateFormatter()
        timestampFormatter.locale = .autoupdatingCurrent
        timestampFormatter.timeZone = .autoupdatingCurrent
        timestampFormatter.dateStyle = .short
        timestampFormatter.timeStyle = .short
        let timestamp = timestampFormatter.string(from: Date())
        var lines: [String] = []
        lines.append("[\(timestamp)] Cleaned \(diskName) (\(diskPath))")
        lines.append("Summary: removed=\(result.removedCount), failed=\(result.failedCount)")
        lines.append("Removed items:")
        if result.removedItems.isEmpty {
            lines.append("  - (none)")
        } else {
            lines.append(contentsOf: result.removedItems.map { "  - \($0)" })
        }
        lines.append("Failed items:")
        if result.failedItems.isEmpty {
            lines.append("  - (none)")
        } else {
            lines.append(contentsOf: result.failedItems.map { "  - \($0)" })
        }
        lines.append("")
        let message = lines.joined(separator: "\n")

        let logsDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
        let logURL = logsDirectory.appendingPathComponent("DiskStat_clean.log", isDirectory: false)

        do {
            try FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)

            if FileManager.default.fileExists(atPath: logURL.path) {
                var existing = try Data(contentsOf: logURL)

                if existing.count > maxLogBytes {
                    existing = Data(existing.suffix(retainLogBytes))
                    if let firstNewline = existing.firstIndex(of: 0x0A) {
                        let afterNewline = existing.index(after: firstNewline)
                        existing = Data(existing.suffix(from: afterNewline))
                    }
                }

                let separator = existing.isEmpty ? "" : "\n"
                if let appended = (separator + message).data(using: .utf8) {
                    existing.append(appended)
                }

                try existing.write(to: logURL, options: .atomic)
            } else {
                try message.write(to: logURL, atomically: true, encoding: .utf8)
            }
        } catch {
            print("Failed to write cleanup log: \(error.localizedDescription)")
        }
    }

    private static func performMacMetadataCleanup(at rootURL: URL) -> CleanupResult {
        let fileManager = FileManager.default
        var result = CleanupResult()

        let rootArtifacts = [
            ".Spotlight-V100",
            ".Trashes",
            ".fseventsd",
            ".TemporaryItems"
        ]

        for name in rootArtifacts {
            let url = rootURL.appendingPathComponent(name, isDirectory: true)
            if fileManager.fileExists(atPath: url.path) {
                do {
                    try fileManager.removeItem(at: url)
                    result.removedItems.append(url.path)
                } catch {
                    result.failedItems.append("\(url.path) (\(error.localizedDescription))")
                }
            }
        }

        if let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsPackageDescendants]
        ) {
            for case let fileURL as URL in enumerator {
                let name = fileURL.lastPathComponent
                guard name == ".DS_Store" || name.hasPrefix("._") else { continue }

                do {
                    try fileManager.removeItem(at: fileURL)
                    result.removedItems.append(fileURL.path)
                } catch {
                    result.failedItems.append("\(fileURL.path) (\(error.localizedDescription))")
                }
            }
        }

        return result
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = DiskMenuController()
app.delegate = delegate
app.run()
