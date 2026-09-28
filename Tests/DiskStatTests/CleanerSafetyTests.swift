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

    // MARK: - Supporting behaviour

    func testCanCleanRejectsInternalAndStartupVolumes() {
        let internalDisk = DiskUsage(
            name: "Macintosh HD", mountURL: URL(fileURLWithPath: "/"),
            totalBytes: 1, freeBytes: 0, isExternal: false, isEjectable: false,
            fileSystem: "apfs", partitionMap: "GUID"
        )
        let bootedExternally = DiskUsage(
            name: "Boot", mountURL: URL(fileURLWithPath: "/"),
            totalBytes: 1, freeBytes: 0, isExternal: true, isEjectable: true,
            fileSystem: "apfs", partitionMap: "GUID"
        )
        let usb = DiskUsage(
            name: "Stick", mountURL: URL(fileURLWithPath: "/Volumes/Stick"),
            totalBytes: 1, freeBytes: 0, isExternal: true, isEjectable: true,
            fileSystem: "msdos", partitionMap: "MBR"
        )

        XCTAssertFalse(DiskCleaner.canClean(internalDisk))
        XCTAssertFalse(DiskCleaner.canClean(bootedExternally))
        XCTAssertTrue(DiskCleaner.canClean(usb))
    }

    func testEjectIsNeverOfferedForTheRunningSystem() {
        let bootedExternally = DiskUsage(
            name: "Boot", mountURL: URL(fileURLWithPath: "/"),
            totalBytes: 1, freeBytes: 0, isExternal: true, isEjectable: true,
            fileSystem: "apfs", partitionMap: "GUID"
        )
        let usb = DiskUsage(
            name: "Stick", mountURL: URL(fileURLWithPath: "/Volumes/Stick"),
            totalBytes: 1, freeBytes: 0, isExternal: true, isEjectable: true,
            fileSystem: "msdos", partitionMap: "MBR"
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

    // MARK: - Classification

    func testArtifactClassification() {
        XCTAssertEqual(MacArtifact(name: ".DS_Store"), .dsStore)
        XCTAssertEqual(MacArtifact(name: "._Film.mkv"), .appleDouble)
        XCTAssertEqual(MacArtifact(name: "@eaDir"), .extendedAttributes)
        XCTAssertEqual(MacArtifact(name: "@eaDir12"), .extendedAttributes)
        XCTAssertEqual(MacArtifact(name: ".Spotlight-V100"), .spotlight)
        XCTAssertEqual(MacArtifact(name: ".fseventsd"), .fileSystemEvents)
        XCTAssertEqual(MacArtifact(name: ".TemporaryItems"), .temporaryItems)

        // Never in scope, and anything unrecognised is left alone.
        XCTAssertNil(MacArtifact(name: ".Trashes"), ".Trashes must never be cleanable")
        XCTAssertNil(MacArtifact(name: "Film.mkv"))
        XCTAssertNil(MacArtifact(name: ".hidden-config"))
        XCTAssertNil(MacArtifact(name: "notes.txt"))
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
        XCTAssertEqual(Set(MacArtifact.allCases).count, 6)
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
