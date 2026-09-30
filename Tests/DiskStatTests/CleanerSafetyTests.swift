import XCTest
@testable import diskstat

/// The cleaner deletes files. These tests exist to make its safety guarantees
/// fail loudly when something breaks them, because none of them are visible in
/// a diff: a cleaner that follows one symlink, or loses the `.Trashes` rule,
/// still looks correct and still compiles.
final class CleanerSafetyTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("diskstat-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Helpers

    private func makeFile(_ relativePath: String) -> URL {
        let url = root.appendingPathComponent(relativePath)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8))
        return url
    }

    private func exists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(relativePath).path)
    }

    @discardableResult
    private func clean() -> CleanResult? {
        DiskCleaner.clean(volume: root, progress: { _ in }, isCancelled: { false })
    }

    // MARK: - The four guarantees

    /// 1. Only known artefacts are removed. Anything unrecognised survives.
    func testRemovesOnlyKnownArtefacts() throws {
        _ = makeFile("Movies/Film.mkv")
        _ = makeFile("Movies/._Film.mkv")
        _ = makeFile("Movies/.DS_Store")
        _ = makeFile("Music/Song.mp3")
        _ = makeFile("@eaDir/0")
        _ = makeFile("notes.txt")

        let result = try XCTUnwrap(clean())

        XCTAssertTrue(exists("Movies/Film.mkv"), "media must survive")
        XCTAssertTrue(exists("Music/Song.mp3"), "media must survive")
        XCTAssertTrue(exists("notes.txt"), "user files must survive")
        XCTAssertFalse(exists("Movies/._Film.mkv"))
        XCTAssertFalse(exists("Movies/.DS_Store"))
        XCTAssertFalse(exists("@eaDir"))
        XCTAssertGreaterThan(result.removedCount, 0)
    }

    /// 2. `.Trashes` holds the user's deleted files. It is data, not clutter.
    func testNeverTouchesTrashes() throws {
        let deleted = makeFile(".Trashes/501/recover-me.docx")
        _ = makeFile(".Trashes/501/.DS_Store")
        _ = makeFile("Movies/.DS_Store")

        _ = try XCTUnwrap(clean())

        XCTAssertTrue(FileManager.default.fileExists(atPath: deleted.path),
                      "a file in .Trashes must survive the clean")
        XCTAssertTrue(exists(".Trashes/501/.DS_Store"))
        XCTAssertFalse(exists("Movies/.DS_Store"), "the rest of the volume still gets cleaned")
    }

    /// 3. Nothing outside the selected volume may be touched, however it is
    ///    reached. `opendir` resolves symlinks, so a stray link on a media
    ///    drive would otherwise pull the walk -- and the deletion -- out of
    ///    the volume.
    func testDoesNotFollowSymlinksOutOfTheVolume() throws {
        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("diskstat-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }

        let secret = outside.appendingPathComponent("._Secret.mov")
        FileManager.default.createFile(atPath: secret.path, contents: Data("x".utf8))
        let dsStore = outside.appendingPathComponent(".DS_Store")
        FileManager.default.createFile(atPath: dsStore.path, contents: Data("x".utf8))

        _ = makeFile("Movies/.DS_Store")
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link"),
            withDestinationURL: outside
        )

        _ = try XCTUnwrap(clean())

        XCTAssertTrue(FileManager.default.fileExists(atPath: secret.path),
                      "a symlink must not pull the cleaner outside the volume")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dsStore.path))
        XCTAssertFalse(exists("Movies/.DS_Store"), "the volume itself is still cleaned")
    }

    /// 4. The startup volume is refused by the deleting function itself, not
    ///    only by the UI that offers the button.
    func testRefusesStartupVolume() {
        XCTAssertNil(
            DiskCleaner.clean(volume: URL(fileURLWithPath: "/"),
                              progress: { _ in }, isCancelled: { false }),
            "clean() must refuse / even if a caller skips canClean"
        )
    }

    /// 5. Markers the user placed on the volume on purpose are left alone. None
    ///    of these are macOS artefacts, and two of them only work if they
    ///    survive: a drive is prepared once, then cleaned repeatedly.
    func testLeavesUserPlacedMarkersAlone() throws {
        // A custom volume icon. Harmless to other devices, and deleting it
        // just throws away something the user chose.
        _ = makeFile(".VolumeIcon.icns")
        // Tells Spotlight to leave the volume alone. No longer honoured by
        // current macOS, but the file costs nothing and may still be doing
        // something on the machine it was placed by.
        _ = makeFile(".metadata_never_index")
        _ = makeFile("Movies/.DS_Store")

        _ = try XCTUnwrap(clean())

        XCTAssertTrue(exists(".VolumeIcon.icns"), "a custom volume icon is not clutter")
        XCTAssertTrue(exists(".metadata_never_index"))
        XCTAssertFalse(exists("Movies/.DS_Store"), "the rest of the volume still gets cleaned")
    }

    /// A `no_log` marker inside `.fseventsd` is how a volume is told not to
    /// journal file system events. Deleting the directory would delete the
    /// marker, and macOS would recreate the directory and start logging again
    /// on the next mount -- so the marker is kept and only the journal goes.
    func testKeepsTheNoLogMarkerButClearsTheJournal() throws {
        _ = makeFile(".fseventsd/no_log")
        _ = makeFile(".fseventsd/1.log")
        _ = makeFile("Movies/.DS_Store")

        let result = try XCTUnwrap(clean())

        XCTAssertTrue(exists(".fseventsd/no_log"),
                      "the marker must survive, or the next mount restarts logging")
        XCTAssertFalse(exists(".fseventsd/1.log"), "the journal itself is still cleaned")
        XCTAssertEqual(result.removedByArtifact[.fileSystemEvents], 1,
                       "the .fseventsd directory is still reported as cleaned")
        XCTAssertFalse(exists("Movies/.DS_Store"))
    }

    /// A `.fseventsd` with no marker is just a macOS artefact, and is removed
    /// outright. Preserving the directory is only for the marker.
    func testRemovesFseventsdThatHasNoMarker() throws {
        _ = makeFile(".fseventsd/1.log")

        _ = try XCTUnwrap(clean())

        XCTAssertFalse(exists(".fseventsd"), "without no_log there is nothing to preserve")
    }

    // MARK: - Supporting behaviour

    func testCanCleanRejectsInternalAndStartupVolumes() {
        let internalDisk = DiskUsage(
            name: "Macintosh HD", mountURL: URL(fileURLWithPath: "/"),
            totalBytes: 1, freeBytes: 0, isExternal: false, isEjectable: false,
            fileSystem: "apfs", partitionMap: "GUID", deviceIdentifier: nil
        )
        let bootedExternally = DiskUsage(
            name: "Boot", mountURL: URL(fileURLWithPath: "/"),
            totalBytes: 1, freeBytes: 0, isExternal: true, isEjectable: true,
            fileSystem: "apfs", partitionMap: "GUID", deviceIdentifier: nil
        )
        let usb = DiskUsage(
            name: "Stick", mountURL: URL(fileURLWithPath: "/Volumes/Stick"),
            totalBytes: 1, freeBytes: 0, isExternal: true, isEjectable: true,
            fileSystem: "msdos", partitionMap: "MBR", deviceIdentifier: nil
        )

        XCTAssertFalse(DiskCleaner.canClean(internalDisk))
        XCTAssertFalse(DiskCleaner.canClean(bootedExternally))
        XCTAssertTrue(DiskCleaner.canClean(usb))
    }

    func testEjectIsNeverOfferedForTheRunningSystem() {
        let bootedExternally = DiskUsage(
            name: "Boot", mountURL: URL(fileURLWithPath: "/"),
            totalBytes: 1, freeBytes: 0, isExternal: true, isEjectable: true,
            fileSystem: "apfs", partitionMap: "GUID", deviceIdentifier: nil
        )
        let usb = DiskUsage(
            name: "Stick", mountURL: URL(fileURLWithPath: "/Volumes/Stick"),
            totalBytes: 1, freeBytes: 0, isExternal: true, isEjectable: true,
            fileSystem: "msdos", partitionMap: "MBR", deviceIdentifier: nil
        )

        XCTAssertFalse(bootedExternally.canEject)
        XCTAssertTrue(usb.canEject)
    }

    func testCancellationRemovesNothing() throws {
        _ = makeFile("Movies/.DS_Store")
        _ = makeFile("Movies/._Film.mkv")

        let result = DiskCleaner.clean(
            volume: root, progress: { _ in }, isCancelled: { true }
        )

        let unwrapped = try XCTUnwrap(result)
        XCTAssertTrue(unwrapped.wasCancelled)
        XCTAssertEqual(unwrapped.removedCount, 0)
        XCTAssertTrue(exists("Movies/.DS_Store"))
        XCTAssertTrue(exists("Movies/._Film.mkv"))
    }

    // MARK: - Reporting a finished clean

    /// The menu line is the primary record of a clean — the notification is not
    /// sent under `swift run`, for an unidentifiable bundle, or when the user
    /// declines the authorisation prompt — so every outcome it can report has to
    /// read correctly, including the ones that only ever happen on a bad day.
    func testLastCleanSummaryReportsEveryOutcome() {
        func summary(
            removed: Int, failed: Int = 0, cancelled: Bool = false, ejectFailed: Bool = false
        ) -> String {
            LastClean(
                removed: removed,
                failed: failed,
                wasCancelled: cancelled,
                ejectFailed: ejectFailed
            ).summary
        }

        // Both counts are always present, in the agreed order, so the line has
        // one shape whatever happened. A zero is shown rather than dropped:
        // "24 removed · 0 failed" is what confirms the clean finished.
        XCTAssertEqual(summary(removed: 1204), "1204 removed · 0 failed")
        XCTAssertEqual(summary(removed: 1204, failed: 4), "1204 removed · 4 failed")

        // Problems are named, because this line is the only place they surface.
        XCTAssertEqual(summary(removed: 0, ejectFailed: true),
                       "0 removed · 0 failed · eject failed")
        XCTAssertEqual(summary(removed: 1200, failed: 4, ejectFailed: true),
                       "1200 removed · 4 failed · eject failed")

        // A cancelled clean neither ejected nor failed, and must not read like a
        // clean finish — it left the volume mounted on purpose.
        XCTAssertEqual(summary(removed: 500, cancelled: true),
                       "cancelled · 500 removed")
        XCTAssertFalse(summary(removed: 500, failed: 3, cancelled: true).contains("failed"),
                       "a cancelled clean did not fail to remove anything")

        // Zero removals is a real outcome — a drive with no artefacts on it.
        XCTAssertEqual(summary(removed: 0), "0 removed · 0 failed")
    }

    /// A finished clean has to leave a log the user can actually open, since
    /// that is the only record that names individual paths.
    func testWriteLogCreatesAReadableFile() throws {
        // A temporary directory, passed in rather than set globally: the real log
        // is the developer's own, and this test appends to it.
        let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("diskstat-log-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        _ = makeFile("Movies/Film.mkv")
        _ = makeFile("Movies/.DS_Store")
        let result = try XCTUnwrap(clean())

        let disk = DiskUsage(
            name: "MYSTICK",
            mountURL: root,
            totalBytes: 1_000,
            freeBytes: 500,
            isExternal: true,
            isEjectable: true,
            fileSystem: "ExFAT",
            partitionMap: "GPT",
            deviceIdentifier: nil
        )
        DiskCleaner.writeLog(disk: disk, result: result, directory: sandbox)

        // The menu item is enabled by this file existing, so this is the
        // condition the feature depends on.
        let written = sandbox.appendingPathComponent("DiskStat_clean.log")
        XCTAssertTrue(FileManager.default.fileExists(atPath: written.path),
                      "a finished clean must leave a log to open")

        let text = try String(contentsOf: written, encoding: .utf8)
        XCTAssertTrue(text.contains("MYSTICK"), "the log must name the volume")
        XCTAssertTrue(text.contains("Summary: removed=1"),
                      "the log must carry the counts")
        // The whole point of the log: the individual path, not just a total.
        XCTAssertTrue(text.contains(".DS_Store"),
                      "the log must name what was removed, not only how much")
    }

    /// The clear-log action has to remove the file, and to report honestly when
    /// there was nothing to remove — the menu item greys out, but the action is
    /// still reachable through the responder chain.
    func testClearLogRemovesTheFileAndReportsWhenThereIsNothing() throws {
        let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("diskstat-clear-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)

        let log = sandbox.appendingPathComponent("DiskStat_clean.log")

        // Nothing there yet: must not claim success, and must not create a file.
        XCTAssertFalse(DiskCleaner.clearLog(at: sandbox),
                       "clearing an empty directory must not claim success")
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path),
                       "clearing must not create a log")

        // A real log goes away, and the caller is told it did.
        try Data("a past clean".utf8).write(to: log)
        XCTAssertTrue(FileManager.default.fileExists(atPath: log.path))
        XCTAssertTrue(DiskCleaner.clearLog(at: sandbox),
                      "clearing an existing log must report success")
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path),
                       "the log must actually be gone")

        // And it does not create one on the way out either.
        XCTAssertFalse(DiskCleaner.clearLog(at: sandbox))
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path))
    }

    /// A clean after a clear must still write a fresh log, so clearing loses
    /// history rather than breaking the feature.
    func testLogIsWrittenAgainAfterBeingCleared() throws {
        let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("diskstat-clear-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let disk = DiskUsage(
            name: "MYSTICK",
            mountURL: root,
            totalBytes: 1_000,
            freeBytes: 500,
            isExternal: true,
            isEjectable: true,
            fileSystem: "ExFAT",
            partitionMap: "GPT",
            deviceIdentifier: nil
        )
        _ = makeFile("Movies/.DS_Store")
        let result = try XCTUnwrap(clean())

        DiskCleaner.writeLog(disk: disk, result: result, directory: sandbox)
        XCTAssertTrue(DiskCleaner.clearLog(at: sandbox))

        _ = makeFile("Music/.DS_Store")
        let second = try XCTUnwrap(clean())
        DiskCleaner.writeLog(disk: disk, result: second, directory: sandbox)

        let log = sandbox.appendingPathComponent("DiskStat_clean.log")
        XCTAssertTrue(FileManager.default.fileExists(atPath: log.path),
                      "a clean after a clear must write a new log")
        let text = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(text.contains("Music"), "the new log is the new run, not the old one")
    }

    // MARK: - Classification

    func testArtifactClassification() {
        XCTAssertEqual(MacArtifact(name: ".DS_Store"), .dsStore)
        XCTAssertEqual(MacArtifact(name: "._Film.mkv"), .appleDouble)
        XCTAssertEqual(MacArtifact(name: "@eaDir"), .extendedAttributes)
        XCTAssertEqual(MacArtifact(name: "@eaDir12"), .extendedAttributes)
        XCTAssertEqual(MacArtifact(name: ".Spotlight-V100"), .spotlight)
        XCTAssertEqual(MacArtifact(name: ".fseventsd"), .fileSystemEvents)
        XCTAssertEqual(MacArtifact(name: ".TemporaryItems"), .temporaryItems)
        XCTAssertEqual(MacArtifact(name: ".apdisk"), .apDisk)

        // Never in scope, and anything unrecognised is left alone.
        XCTAssertNil(MacArtifact(name: ".Trashes"), ".Trashes must never be cleanable")
        XCTAssertNil(MacArtifact(name: "Film.mkv"))
        XCTAssertNil(MacArtifact(name: ".hidden-config"))
        XCTAssertNil(MacArtifact(name: "notes.txt"))

        // `.apdisk` must match only exactly. It is the one artefact whose name
        // is a near-miss for another rule: a case-insensitive or prefix match
        // would drag `apdisk.bak` and friends in with it.
        XCTAssertNil(MacArtifact(name: "apdisk"))
        XCTAssertNil(MacArtifact(name: ".apdisk.bak"))
        XCTAssertNil(MacArtifact(name: ".apdisk2"))
    }

    /// `.apdisk` is removed, and it is counted as its own type so the log can
    /// account for it.
    func testRemovesApDiskMarker() throws {
        _ = makeFile(".apdisk")
        _ = makeFile("notes.txt")

        let result = try XCTUnwrap(clean())

        XCTAssertFalse(exists(".apdisk"))
        XCTAssertEqual(result.removedByArtifact[.apDisk], 1)
        XCTAssertTrue(exists("notes.txt"), "user files must survive")
    }

    // MARK: - Log summary

    func testCleanResultGroupsRemovedItemsByType() {
        let volume = FileManager.default.temporaryDirectory
            .appendingPathComponent("diskstat-log-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: volume.appendingPathComponent("Media/Film.mkv"),
            withIntermediateDirectories: true
        )
        for sidecar in ["._Film.mkv", "._Poster.jpg"] {
            try? Data("x".utf8).write(to: volume.appendingPathComponent("Media/\(sidecar)"))
        }
        try? Data("x".utf8).write(to: volume.appendingPathComponent(".DS_Store"))
        defer { try? FileManager.default.removeItem(at: volume) }

        let result = DiskCleaner.clean(volume: volume, progress: { _ in }, isCancelled: { false })

        XCTAssertEqual(result?.removedCount, 3)
        XCTAssertEqual(result?.failedCount, 0)
        XCTAssertEqual(result?.removedByArtifact[.dsStore], 1)
        XCTAssertEqual(result?.removedByArtifact[.appleDouble], 2)
        // The real file is untouched, and it is not counted as removed.
        XCTAssertNil(result?.removedByArtifact[.temporaryItems])
        XCTAssertTrue(FileManager.default.fileExists(atPath: volume.appendingPathComponent("Media/Film.mkv").path))
    }

    func testEveryArtifactAppearsInTheSummaryOrder() {
        // Guards against an artefact being added to the enum but forgotten in the
        // log's "By type" section, which would silently under-report it.
        XCTAssertEqual(Set(MacArtifact.allCases).count, 7)
        for artifact in MacArtifact.allCases {
            XCTAssertFalse(artifact.summary.isEmpty)
        }
    }

    // MARK: - Version

    /// The version shown when there is no bundle has to come from the same tag
    /// the bundle is built from, otherwise the app reports two different
    /// numbers depending only on how it was launched. This pins the generated
    /// file to the tag, which is the one thing here that can silently drift.
    func testGeneratedVersionMatchesTheLatestGitTag() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CleanerSafetyTests.swift
            .deletingLastPathComponent()   // DiskStatTests
            .deletingLastPathComponent()   // repo root

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path, "describe", "--tags", "--abbrev=0"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // Deliberately not a skip: a silent skip here once hid a wrong root
        // path, and a version guard that quietly stops guarding is worse than
        // one that fails.
        XCTAssertEqual(process.terminationStatus, 0,
                       "git describe failed in \(root.path) — wrong repo root?")

        let tag = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(tag.isEmpty)

        // `git describe` reports the most recent *annotated* tag: a lightweight
        // tag on the same commit loses to an annotated one, so the release tag
        // has to be created with -a for this to hold.
        XCTAssertEqual(generatedVersion, String(tag.dropFirst()),
                       "run ./scripts/set_version.sh after tagging, and tag with -a")
    }
}
