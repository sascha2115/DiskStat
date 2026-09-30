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

/// Filesystem and partition scheme of a volume, as reported by `diskutil`.
struct DiskMeta: Equatable {
    let fileSystem: String
    let partitionMap: String

    static let unknown = DiskMeta(fileSystem: "Unknown", partitionMap: "Unknown")
}
