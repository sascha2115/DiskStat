import XCTest
@testable import diskstat

/// A regression found on a real exFAT card, not in review.
///
/// On exFAT and FAT, a file that carries extended attributes also has an
/// AppleDouble sidecar beside it: a `.DS_Store` with an xattr gets a
/// `._.DS_Store`. Both match this cleaner. Removing the `.DS_Store` makes the
/// kernel delete its sidecar as well, so the cleaner's own entry for
/// `._.DS_Store` was then removed from a file that no longer existed, and
/// FileManager reported "“._.DS_Store” couldn't be removed."
///
/// The volume came out clean. Only the count was wrong — but the run reported
/// failures, which sent the user looking for a problem that was not there.
///
/// The fixture is a real exFAT disk image, because the behaviour is a property
/// of the filesystem: the sidecar is not consulted the same way on APFS and the
/// bug does not occur there, so a temp-directory test would pass for the wrong
/// reason. The image is created and destroyed per test.
final class SidecarOfArtefactTests: XCTestCase {
    /// 11 characters, which is the limit for a FAT-family volume name.
    /// `hdiutil create -fs ExFAT` fails with "Operation not permitted" on a
    /// longer one, and the error does not mention the name at all.
    private let volumeName = "DISKSTAT_T1"
    private var volume: URL!
    private var image: URL!

    override func setUpWithError() throws {
        image = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sidecar-\(UUID().uuidString).dmg")

        // -ov: hdiutil refuses to overwrite, and a leftover from a crashed run
        // would otherwise fail the setup rather than being replaced.
        let create = Process()
        create.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        create.arguments = ["create", "-ov", "-size", "64m", "-fs", "ExFAT",
                            "-volname", volumeName, image.path]
        try create.run()
        create.waitUntilExit()
        guard create.terminationStatus == 0 else {
            throw XCTSkip("hdiutil could not create a test image on this machine")
        }

        let attach = Process()
        attach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        attach.arguments = ["attach", image.path]
        try attach.run()
        attach.waitUntilExit()
        guard attach.terminationStatus == 0 else {
            throw XCTSkip("hdiutil could not mount a test image on this machine")
        }

        volume = URL(fileURLWithPath: "/Volumes/\(volumeName)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: volume.path),
                      "the test image should be mounted")
    }

    override func tearDownWithError() throws {
        let detach = Process()
        detach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        detach.arguments = ["detach", "/Volumes/\(volumeName)", "-quiet"]
        try? detach.run()
        detach.waitUntilExit()
        try? FileManager.default.removeItem(at: image)
    }

    /// A `.DS_Store` carrying an xattr, which is what makes exFAT write the
    /// `._.DS_Store` sidecar beside it.
    private func makeStoreWithSidecar(in dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("film".utf8).write(to: dir.appendingPathComponent("Episode.mkv"))
        let store = dir.appendingPathComponent(".DS_Store")
        try Data("store".utf8).write(to: store)

        let xattr = Process()
        xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattr.arguments = ["-w", "com.apple.metadata:_kMDItemUserTags", "t", store.path]
        try xattr.run()
        xattr.waitUntilExit()
        XCTAssertEqual(xattr.terminationStatus, 0, "could not set the xattr")

        // Assert the sidecar was really produced, so a filesystem that stopped
        // writing one cannot make this test pass for the wrong reason. readdir,
        // not FileManager: FileManager hides AppleDouble files, which is the
        // very reason the cleaner uses readdir.
        var names: [String] = []
        guard let handle = opendir(dir.path) else {
            return XCTFail("could not read the fixture directory")
        }
        defer { closedir(handle) }
        while let entry = readdir(handle) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw -> String in
                String(decoding: raw.bindMemory(to: UInt8.self).prefix(while: { $0 != 0 }),
                       as: UTF8.self)
            }
            if name != "." && name != ".." { names.append(name) }
        }
        XCTAssertTrue(names.contains("._.DS_Store"),
                      "fixture did not produce the sidecar; this test would be vacuous")
    }

    /// The reported bug: the sidecar of a `.DS_Store` was reported as a failure.
    func testSidecarOfADatStoreIsNotReportedAsFailure() throws {
        let dir = volume.appendingPathComponent("All TV Shows/Wilsberg (1995)/S01E91 - Einfach weg")
        try makeStoreWithSidecar(in: dir)

        let result = try XCTUnwrap(DiskCleaner.clean(volume: volume,
                                                     progress: { _ in },
                                                     isCancelled: { false }))

        XCTAssertEqual(result.failedPaths, [],
                       "a sidecar the kernel already removed is not a failure")
        XCTAssertEqual(result.removedCount, result.removedPaths.count)

        // The media survives, as everywhere else.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("Episode.mkv").path
        ), "media must survive the clean")
    }

    /// The counter-case. A real failure must still be reported, or the fix would
    /// be hiding genuine problems along with this one.
    ///
    /// An immutable file is used rather than an unreadable directory: the file
    /// is found by the scan, so the removal genuinely fails, and the fixture
    /// cannot leave the rest of the volume unreadable for other tests.
    func testGenuineFailureIsStillReported() throws {
        let dir = volume.appendingPathComponent("Locked")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = dir.appendingPathComponent(".DS_Store")
        try Data("store".utf8).write(to: store)

        let flags = Process()
        flags.executableURL = URL(fileURLWithPath: "/usr/bin/chflags")
        flags.arguments = ["uchg", store.path]
        try flags.run()
        flags.waitUntilExit()
        defer {
            let clear = Process()
            clear.executableURL = URL(fileURLWithPath: "/usr/bin/chflags")
            clear.arguments = ["nouchg", store.path]
            try? clear.run()
            clear.waitUntilExit()
        }
        XCTAssertEqual(flags.terminationStatus, 0, "could not set the immutable flag")

        let result = try XCTUnwrap(DiskCleaner.clean(volume: volume,
                                                     progress: { _ in },
                                                     isCancelled: { false }))

        XCTAssertTrue(FileManager.default.fileExists(atPath: store.path),
                      "an immutable file cannot be removed; it should still be there")
        XCTAssertFalse(result.removedPaths.contains(store.path),
                       "a file that could not be removed must not be counted as removed")
        XCTAssertFalse(result.failedPaths.isEmpty,
                       "a genuine failure must still be reported")
    }
}
