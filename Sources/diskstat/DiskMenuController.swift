import AppKit
import Darwin
import Foundation
import UserNotifications

/// The outcome of the most recent clean, as shown on one line in the menu.
///
/// At file scope rather than nested in the controller so the wording can be
/// tested: it is the part of the feature a user actually reads, and a wrong or
/// missing clause is invisible in a diff.
struct LastClean {
    let removed: Int
    let failed: Int
    let wasCancelled: Bool
    let ejectFailed: Bool

    /// One line, kept short enough not to wrap the menu: `1204 removed · 4
    /// failed`.
    ///
    /// Both counts are always shown, including a zero. A consistent shape is
    /// worth more here than dropping a clause, and "24 removed · 0 failed" is
    /// what tells the user the clean completed rather than silently stopping
    /// early.
    ///
    /// A cancelled run is not expressed through the counts, because it is not a
    /// run with a small failure count: it stopped partway and the volume was
    /// deliberately left mounted. It replaces the counts with its own wording
    /// so it can never be misread as a clean finish.
    var summary: String {
        if wasCancelled {
            return "cancelled · \(removed) removed"
        }

        var parts = ["\(removed) removed", "\(failed) failed"]
        if ejectFailed {
            parts.append("eject failed")
        }
        return parts.joined(separator: " · ")
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

    /// The outcome of the most recent clean, shown in the menu once it is
    /// rebuilt.
    ///
    /// This is not a backup for the notification, it is the *primary* record.
    /// `canUseUserNotifications` is false under `swift run` and for any bundle
    /// without an identifier, and a user who declines the authorisation prompt
    /// would otherwise get no confirmation at all. A clean usually finishes in
    /// about a second, so there is no window in which a progress window would
    /// be worth having either; the menu is simply where the answer already is.
    private var lastClean: LastClean?

    /// Shown next to the title in the menu.
    ///
    /// The bundle wins when there is one, so the `.app` reports exactly what
    /// `scripts/build_app.sh` tagged. A bare `swift run` has no bundle to read,
    /// so it falls back to `generatedVersion` from `Version.swift`, which
    /// `scripts/set_version.sh` writes from the same tag.
    private let appVersion: String = {
        if let bundled = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           !bundled.isEmpty
        {
            return bundled
        }
        return generatedVersion
    }()

    /// User notifications only work from a real, identified app bundle. Under
    /// `swift run` there is none, and the authorisation request would silently
    /// do nothing, so the guard keeps that path quiet.
    private let canUseUserNotifications: Bool = {
        Bundle.main.bundleURL.pathExtension.lowercased() == "app"
            && Bundle.main.bundleIdentifier != nil
    }()

    private func requestNotificationAuthorization() {
        guard canUseUserNotifications else { return }
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Reports the outcome of a clean. This is the only feedback the user gets
    /// if the menu was closed while the clean ran — the row showing the result
    /// is not on screen in that case.
    private func postCleanupNotification(
        diskName: String,
        result: CleanResult,
        ejectError: Error?
    ) {
        guard canUseUserNotifications else { return }

        let content = UNMutableNotificationContent()
        if ejectError == nil {
            content.title = "Disk cleaned and ejected"
            content.body = "\(diskName): removed \(result.removedCount), failed \(result.failedCount)."
        } else {
            content.title = "Disk cleaned (eject failed)"
            content.body = "\(diskName): removed \(result.removedCount), "
                + "failed \(result.failedCount). \(ejectError?.localizedDescription ?? "")"
        }
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "diskstat.cleanup.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

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
        requestNotificationAuthorization()
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

        let titleItem = NSMenuItem(title: "DiskStat \(appVersion)", action: nil, keyEquivalent: "")
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

        // The outcome of the last clean, so the answer survives the menu closing
        // and the volume disappearing from the list after the eject. Disabled
        // like the title: it is a label, not something to click.
        if let lastClean {
            let item = NSMenuItem(title: "Last clean: \(lastClean.summary)",
                                 action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            menu.addItem(.separator())
        }

        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let storageSettingsItem = NSMenuItem(title: "Open Storage Settings…", action: #selector(openStorageSettings), keyEquivalent: "")
        storageSettingsItem.target = self
        menu.addItem(storageSettingsItem)

        // Only enabled once a clean has actually written one, so it cannot offer
        // to open a file that is not there.
        let logItem = NSMenuItem(title: "Show Clean Log…", action: #selector(showCleanLog), keyEquivalent: "")
        logItem.target = self
        logItem.isEnabled = FileManager.default.fileExists(atPath: DiskCleaner.logURL.path)
        menu.addItem(logItem)

        // No confirmation. The log is regenerated by the next clean, so the only
        // thing lost is history, and the item is worded to make that obvious.
        let clearLogItem = NSMenuItem(title: "Clear Clean Log", action: #selector(clearCleanLog), keyEquivalent: "")
        clearLogItem.target = self
        clearLogItem.isEnabled = FileManager.default.fileExists(atPath: DiskCleaner.logURL.path)
        clearLogItem.toolTip = "Delete the log of previous cleans"
        menu.addItem(clearLogItem)

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

    /// Opens the clean log.
    ///
    /// The log is the only complete record of what was removed — the menu line
    /// and the notification both carry counts only, and the log is the one place
    /// that names individual paths when something needs looking at.
    @objc private func showCleanLog() {
        let url = DiskCleaner.logURL
        // The menu item is disabled without a log, but the action can still be
        // reached by the responder chain, so the existence check stays.
        guard FileManager.default.fileExists(atPath: url.path) else {
            NSSound.beep()
            return
        }

        // `open`, not `activateFileViewerSelecting`: the user asked to see the
        // log's contents, not to pick it out in a Finder window. A .log opens
        // in the default text viewer.
        if !NSWorkspace.shared.open(url) {
            NSSound.beep()
        }
    }

    /// Deletes the clean log. No confirmation: the log is a record, not data,
    /// and the next clean writes a new one.
    @objc private func clearCleanLog() {
        guard DiskCleaner.clearLog() else {
            NSSound.beep()
            return
        }

        // Both log items are enabled from the file's existence, so the menu has
        // to be rebuilt for them to grey out. Deferred if the menu is open, which
        // is the case here: the click is still being tracked.
        rebuildMenuIfIdle()
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
                    self.recordLastClean(
                        LastClean(
                            removed: result.removedCount,
                            failed: result.failedCount,
                            wasCancelled: true,
                            ejectFailed: false
                        )
                    )
                    return
                }

                let ejectError = self.ejectDisk(disk)
                self.recordLastClean(
                    LastClean(
                        removed: result.removedCount,
                        failed: result.failedCount,
                        wasCancelled: false,
                        ejectFailed: ejectError != nil
                    )
                )

                // Only a problem is worth putting in the row. On a clean run the
                // normal size reading is the more useful thing to show, and the
                // summary line already carries the count.
                if result.failedCount > 0 || ejectError != nil {
                    let detail = result.failedCount > 0
                        ? "Cleaned · \(result.removedCount) removed · \(result.failedCount) failed"
                        : "Cleaned · \(result.removedCount) removed · eject failed"
                    self.currentRow(for: disk)?.setStatus(detail, percent: "")
                }

                self.postCleanupNotification(
                    diskName: disk.name,
                    result: result,
                    ejectError: ejectError
                )
            }
        }
    }

    /// Stores the outcome and refreshes the menu, so the next open shows it.
    private func recordLastClean(_ summary: LastClean) {
        lastClean = summary
        // The eject that just happened will drop the row from the list anyway,
        // and this is off the main thread's critical path by a hair, but
        // rebuilding here is what makes the line appear immediately when the
        // menu is reopened. `rebuildMenuIfIdle` defers it if the menu is open.
        rebuildMenuIfIdle()
    }

    @discardableResult
    private func ejectDisk(_ disk: DiskUsage) -> Error? {
        // Re-checked here as well: the button is only a hint, and the clean
        // action reaches this path too. The error is returned so the clean can
        // report the outcome, not just swallow it into a beep.
        guard disk.canEject else { return DiskStatError.notEjectable(disk.path) }

        var ejectError: Error?
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
            ejectError = error
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

        return ejectError
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
