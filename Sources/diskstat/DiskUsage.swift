import Foundation

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
