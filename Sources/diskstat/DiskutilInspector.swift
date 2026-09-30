import AppKit
import Darwin
import Foundation

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
