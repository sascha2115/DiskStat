import Foundation

/// Errors this app raises itself, as opposed to system ones.
enum DiskStatError: LocalizedError {
    case notEjectable(String)

    var errorDescription: String? {
        switch self {
        case .notEjectable(let path):
            return "\(path) is not a volume that can be ejected"
        }
    }
}

/// Minimal thread-safe box for values produced on a background queue.
final class SynchronizedBox<Value>: @unchecked Sendable {
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

/// Filesystem, partition scheme and device of a volume, as reported by `diskutil`.
struct DiskMeta: Equatable {
    let fileSystem: String
    let partitionMap: String

    /// The kernel's name for the volume's device, e.g. `disk4s2` — without the
    /// `/dev/` prefix that `DeviceNode` carries.
    ///
    /// Worth showing because it is the name macOS uses when it *refuses* to do
    /// something: "The disk disk4s2 wasn't ejected properly because a file was in
    /// use", or a `diskutil` error pasted into a bug report. A volume name on
    /// its own ("MEDIADISK") matches none of that.
    ///
    /// Optional, and nil when unknown, rather than the "Unknown" placeholder the
    /// other two use: there is no sensible text to put there, and a row reading
    /// "exFAT • GUID • Unknown" is worse than one reading "exFAT • GUID".
    let deviceIdentifier: String?

    static let unknown = DiskMeta(
        fileSystem: "Unknown",
        partitionMap: "Unknown",
        deviceIdentifier: nil
    )
}
